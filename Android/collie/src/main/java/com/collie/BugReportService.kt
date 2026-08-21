package com.collie

import android.content.Context
import com.collie.internal.CollieSessionTracker
import com.collie.internal.IngestionClient
import com.collie.internal.PendingUploadScheduler
import com.collie.internal.ReportEnvelopeBuilder
import com.collie.internal.UploadQueue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Outcome of a report submission (the UI shows a toast/error based on this). */
public sealed interface CollieSubmitOutcome {
    /** The backend accepted the report. Carries the server's report id. */
    public data class Sent(public val reportId: String) : CollieSubmitOutcome

    /**
     * Transient failure — the report was queued to disk and will be retried
     * automatically once a connection is available.
     */
    public data object Queued : CollieSubmitOutcome

    /** Permanent failure (auth/validation) — could not be sent and was not queued. */
    public data class Rejected(public val reason: String) : CollieSubmitOutcome
}

/**
 * The bug reporter's working engine: gathers report data, produces the upload envelope,
 * and hands it to the offline-capable queue.
 *
 * The UI (shake detector / banner / sheet) uses this service via
 * [Collie.bugReportService]. The service only exists after a valid
 * `Collie.configure(context, config)` with `enabled = true`; otherwise it is `null` → the
 * UI installs nothing.
 */
public class BugReportService internal constructor(
    internal val configuration: CollieConfiguration,
    private val appContext: Context,
    transport: ReportTransport?,
) {

    private val transport: ReportTransport = transport ?: IngestionClient(configuration)

    /**
     * The destination's own screenshot limit, read once — a transport is fixed for the
     * lifetime of the service.
     */
    private val transportMaxScreenshotBytes: Int? = this.transport.maxScreenshotBytes

    private val queue = UploadQueue(
        configuration = configuration,
        transport = this.transport,
        directory = UploadQueue.defaultDirectory(appContext.cacheDir),
    )

    private val pendingUploadScheduler = PendingUploadScheduler(appContext, ::diag)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Server-side switches. */
    private val remoteCaptureEnabled = AtomicBoolean(true)
    private val remoteMaxScreenshotBytes = AtomicInteger(0)
    private val remoteMaxScreenshots = AtomicInteger(0)

    /**
     * Logical sessions, the persistent report counters, and the session markers that go into
     * `entries`. See [CollieSessionTracker].
     */
    internal val sessions = CollieSessionTracker(
        store = CollieSessionTracker.preferencesStore(appContext),
    )

    /**
     * When Collie was configured — written into every report as a synthetic
     * "Session started" log entry, and as the envelope's `processStartedAt`.
     */
    internal val initializedAtMillis: Long get() = sessions.processStartedAtMillis

    // MARK: - Lifecycle (called from configure)

    /**
     * Fetches the server-side kill switch and drains the pending queue (once at startup), and
     * starts watching the background/foreground transitions that end one logical session and
     * open the next.
     */
    internal fun bootstrap() {
        sessions.startObservingLifecycle()
        scope.launch {
            refreshRemoteConfig()
            // WorkManager also recreates the application before running its worker. Treat the
            // startup drain as durable background work so repeated process recreation cannot
            // consume the foreground retry limit and discard a VPN-blocked report.
            queue.drain(retainTransientFailures = true)
            scheduleBackgroundRetryIfNeeded()
        }
    }

    /**
     * Attempts to send pending offline reports (e.g. when the app returns to the
     * foreground or a VPN connection is established).
     */
    public fun flushPendingUploads() {
        scope.launch {
            queue.drain()
            scheduleBackgroundRetryIfNeeded()
        }
    }

    /** Called by WorkManager after the host process has been recreated. */
    internal suspend fun retryPendingUploadsInBackground(): Boolean {
        // A background job must not discard a report merely because a VPN stayed active
        // through several scheduled attempts. Permanent failures and the 48-hour TTL still
        // remove it; transient failures remain available for the next WorkManager run.
        queue.drain(retainTransientFailures = true)
        return queue.pendingCount() == 0
    }

    private fun scheduleBackgroundRetryIfNeeded() {
        if (queue.pendingCount() > 0) pendingUploadScheduler.schedule()
    }

    // MARK: - Capture gate

    /**
     * Refreshes the server-side switches.
     *
     * **Fails open on an unreachable backend**: when the config call fails (no VPN,
     * offline) the previous value is kept, so a tester can still capture a report and
     * have it queued. Only an explicit `captureEnabled: false` from the server turns
     * capture off — that is also what an invalid api-key yields (the backend answers
     * fail-closed).
     */
    private suspend fun refreshRemoteConfig() {
        val config = transport.fetchRemoteConfig()
        if (config == null) {
            diag("Remote config unreachable — keeping the current capture state.")
            return
        }
        remoteCaptureEnabled.set(config.captureEnabled)
        remoteMaxScreenshotBytes.set(config.maxScreenshotBytes?.takeIf { it > 0 } ?: 0)
        // Clamped on the way in: the panel reads a fixed number of slots, so a server value
        // above the ceiling would only capture images it will never display.
        remoteMaxScreenshots.set(
            config.maxScreenshots
                ?.takeIf { it > 0 }
                ?.coerceAtMost(CollieConfiguration.MAX_SCREENSHOTS_LIMIT)
                ?: 0,
        )
        if (!config.captureEnabled) {
            diag("Capture is disabled server-side for this app (kill switch).")
        }
    }

    /**
     * Is capture currently active? Two gates: the local build-time opt-in (this service
     * only exists when that passed) **and** the server-side kill switch.
     */
    public val isCaptureEnabled: Boolean get() = remoteCaptureEnabled.get()

    /**
     * Byte limit for **one** screenshot: the strictest of the local config, the server's
     * value, and whatever the transport says it can actually store. A report carrying five
     * images is bounded five times over, once per image, because each one travels separately.
     *
     * The transport's limit belongs here rather than only at the transport, because this is
     * the number the form compresses against. Leave it out and the two disagree: the image is
     * encoded to fit 4 MB, then dropped for being over 650 KB — with the report going
     * through, minus the picture.
     */
    public val maxScreenshotBytes: Int
        get() {
            var limit = configuration.maxScreenshotBytes
            val remote = remoteMaxScreenshotBytes.get()
            if (remote > 0) limit = minOf(limit, remote)
            transportMaxScreenshotBytes?.let { limit = minOf(limit, it) }
            return limit
        }

    /**
     * How many screenshots a report may carry — the stricter of the local config and the
     * server's value, never above [CollieConfiguration.MAX_SCREENSHOTS_LIMIT]. The form
     * stops offering to add one at this number.
     */
    public val maxScreenshots: Int
        get() {
            val remote = remoteMaxScreenshots.get()
            return if (remote <= 0) {
                configuration.effectiveMaxScreenshots
            } else {
                minOf(configuration.effectiveMaxScreenshots, remote)
            }
        }

    /** JPEG compression quality. */
    public val screenshotJpegQuality: Double get() = configuration.effectiveJpegQuality

    // MARK: - Identity (does the sheet ask for a name on first use?)

    /** Has a tester name been stored before? */
    public val hasStoredTesterName: Boolean
        get() = CollieDeviceIdentity.hasStoredName(appContext)

    /** Stores the one-time tester name. */
    public fun storeTesterName(name: String) {
        CollieDeviceIdentity.storeName(appContext, name)
    }

    // MARK: - Submission

    /**
     * Sends the report: one upload carrying the JSON envelope (app/device/report meta +
     * **all** log entries + telemetry) and the screenshots. Triage and the eventual Jira
     * issue happen in the analyst panel.
     *
     * @param whatHappened The "What happened?" field.
     * @param testerName Name entered on the first submission (stored afterwards); when
     *   `null`, the stored name is used.
     * @param screenshotsJpeg The screenshots pre-compressed to JPEG (binary), in the order
     *   the tester arranged them. Empty when the report carries no image.
     */
    public suspend fun sendReport(
        whatHappened: String,
        testerName: String?,
        screenshotsJpeg: List<ByteArray>,
        identity: CollieDeviceIdentity,
        telemetry: CollieTelemetry? = null,
    ): CollieSubmitOutcome {
        if (!testerName.isNullOrBlank()) {
            CollieDeviceIdentity.storeName(appContext, testerName)
        }
        val effectiveName = testerName
            ?: identity.name
            ?: CollieDeviceIdentity.storedName(appContext)

        // Whole seconds: `capturedAt` is stored as the next report's `previousReportAt`, and
        // both are encoded by a formatter that drops the milliseconds. Rounding down here
        // means the two strings are identical rather than a fraction of a second apart — the
        // panel compares them for equality to place the fold boundary.
        val capturedAtMillis = (System.currentTimeMillis() / 1_000L) * 1_000L
        val stamp = sessions.stampForReport(capturedAtMillis)

        // The host's log snapshot — ALL categories, raw entries, nothing dropped — plus
        // Collie's own session markers, merged in at their chronological positions so the
        // timeline shows where this session began, where it resumed after a long background,
        // and where the previous report was filed.
        val hostEntries = configuration.logSnapshotProvider?.invoke().orEmpty()
        val entries = CollieSessionTracker.merge(
            hostEntries = hostEntries,
            markers = CollieSessionTracker.markerEntries(stamp),
        )

        val context = ReportEnvelopeBuilder.ReportContext(
            whatHappened = whatHappened,
            testerName = effectiveName,
            identity = identity,
            telemetry = telemetry,
            sessionId = configuration.sessionIdProvider?.invoke().orEmpty(),
            capturedAtMillis = capturedAtMillis,
            entries = entries,
            session = stamp,
        )

        val reportBody = runCatching {
            ReportEnvelopeBuilder.makeBody(configuration = configuration, context = context)
        }.getOrNull() ?: return CollieSubmitOutcome.Rejected("Could not build the report envelope")

        return queue.submit(reportBody = reportBody, screenshots = screenshotsJpeg).also { outcome ->
            if (outcome is CollieSubmitOutcome.Queued) pendingUploadScheduler.schedule()
        }
    }

    internal fun diag(message: String) {
        configuration.diagnostics?.invoke("[Collie] $message")
    }
}
