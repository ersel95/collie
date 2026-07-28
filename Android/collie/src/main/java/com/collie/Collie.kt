package com.collie

import android.app.Application
import android.content.Context
import com.collie.ui.CollieUi

/**
 * Collie's public facade: screenshot → banner → form → **report in the analyst panel**.
 * **OPT-IN, disabled by default.**
 *
 * Unless [configure] is called — or when it is called with `enabled = false`
 * (the default) — **no** detector / network / upload code runs at all.
 *
 * The device never talks to Jira: it uploads the report to the Collie backend, where an
 * analyst triages it and pushes it to Jira from the panel.
 *
 * ```kotlin
 * // Default: off. To enable (backend settings come from the host's BuildConfig):
 * Collie.configure(
 *     context = this,
 *     configuration = CollieConfiguration(
 *         enabled = BuildConfig.COLLIE_ENABLED,
 *         apiBaseUrl = BuildConfig.COLLIE_API_BASE_URL,
 *         apiKey = BuildConfig.COLLIE_API_KEY,
 *         environment = "staging",
 *         logSnapshotProvider = { Olaf.snapshot().map { … } },   // optional
 *     ),
 * )
 * ```
 */
public object Collie {

    @Volatile
    private var service: BugReportService? = null

    private val lock = Any()

    // MARK: - Configure (single entry point)

    /**
     * Configures the bug reporter. **`CollieConfiguration.enabled` defaults to `false`** → opt-in.
     *
     * DEFENSE LAYERS (against accidental activation in release builds):
     *  1. Build-time opt-in (`enabled`): defaults to `false`. Until this gate passes,
     *     no sensor/network/upload code runs (early return below).
     *  2. Fail-closed validation: if any required backend field (`apiKey`, `apiBaseUrl`,
     *     the endpoint paths) is blank, nothing is installed.
     *  3. The `collie-no-op` artifact, which a release build links instead of this one, so
     *     none of this code is even present in a production APK.
     *
     * The host must never pass a hard-coded `enabled = true` in release builds; the value
     * must come from a BuildConfig field fed by non-prod secrets.
     *
     * Idempotent; if called again, the first configuration is kept.
     *
     * @param transport Where reports are sent. Defaults to Collie's own HTTPS ingestion
     *   client. Pass a custom one — e.g. `FirestoreTransport` from the `collie-firebase`
     *   artifact — when the host's network policy only permits certain destinations.
     */
    @JvmStatic
    @JvmOverloads
    public fun configure(
        context: Context,
        configuration: CollieConfiguration,
        transport: ReportTransport? = null,
    ) {
        // Gate 1: local opt-in (build-time defense). If off, do nothing.
        if (!configuration.enabled) return

        // Gate 2: required backend fields — fail-closed. A custom transport brings its
        // own destination and credentials, so the HTTPS-ingestion fields are not
        // required in that case.
        if (transport == null) {
            val error = configuration.validationError
            if (error != null) {
                configuration.diagnostics?.invoke(
                    "[Collie] configure: $error — bug reporter not started.",
                )
                return
            }
        }

        val appContext = context.applicationContext
        synchronized(lock) {
            // Idempotent: keep the first installation.
            if (service != null) return
            service = BugReportService(
                configuration = configuration,
                appContext = appContext,
                transport = transport,
            )
        }

        // Try to drain the pending (offline) queue.
        service?.bootstrap()

        // UI side (shake detector + banner). Without an Application there is no activity to
        // attach to, so the reporter stays reachable only through `presentReport()`.
        val application = appContext as? Application
        if (application != null) {
            CollieUi.install(application)
        } else {
            configuration.diagnostics?.invoke(
                "[Collie] configure: no Application context — shake activation is unavailable.",
            )
        }
    }

    // MARK: - Manual entry points

    /**
     * Opens the report form directly, skipping the "Spotted a problem?" question.
     *
     * Use this when the tester has *already* said they want to report — typically when
     * handing off from another diagnostics tool (see [onLogoTap]). A shake still goes
     * through `asksBeforeReporting`, because a shake can be accidental; a deliberate
     * hand-off cannot, so asking again is just a dead click.
     *
     * No-op when the reporter is off, capture is disabled server-side, or the Collie UI is
     * already on screen.
     */
    @JvmStatic
    public fun presentReport() {
        CollieUi.present(askFirst = false)
    }

    /**
     * Registers a handler for taps on the Collie logo in the report screen's top bar.
     *
     * When a handler is set, the logo becomes a button: tapping it closes the Collie UI and
     * invokes the handler **after** the UI has fully closed, so it is safe to open another
     * diagnostics tool from the handler. Useful when Collie is installed alongside another
     * shake-activated tool (Olaf): the host wires the two callbacks to switch between them.
     * Pass `null` to remove the handler (the logo becomes a plain mark again).
     *
     * The handler does **not** affect shake behaviour: whether a shake asks first or opens
     * the report form directly is decided solely by `CollieConfiguration.asksBeforeReporting`.
     */
    @JvmStatic
    public fun onLogoTap(handler: (() -> Unit)?) {
        CollieUi.logoTapHandler = handler
    }

    // MARK: - Access

    /**
     * The active bug-report service. `null` unless a valid `configure(...)` with
     * `enabled = true` happened. The UI uses this to submit reports; when `null`, no UI is
     * installed.
     */
    @JvmStatic
    public val bugReportService: BugReportService?
        get() = service

    /** Is the bug reporter currently active? (configured + service exists) */
    @JvmStatic
    public val isConfigured: Boolean
        get() = service != null

    /**
     * Attempts to send pending offline reports (call e.g. on returning to foreground
     * or once a VPN connection is established).
     */
    @JvmStatic
    public fun flushPendingUploads() {
        service?.flushPendingUploads()
    }

    /** Resets global state for tests. Never called in production code. */
    internal fun resetForTesting() {
        synchronized(lock) { service = null }
    }
}
