package com.collie.internal

import com.collie.CollieConfiguration
import com.collie.CollieOperationResult
import com.collie.CollieSubmitOutcome
import com.collie.ReportTransport
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.util.UUID
import kotlin.math.pow

/**
 * Persistent (offline) upload queue on disk. Failed reports are stored under
 * `cacheDir/collie/uploads/` and retried with exponential backoff. Pending reports are
 * read back from disk and sending continues even after a process restart.
 *
 * **One report = one request.** The envelope id doubles as the idempotency key sent to
 * the backend, so a retry after a lost response resolves to the same report instead of
 * creating a duplicate (`UploadQueueTest` locks this in).
 *
 * Concurrency: every entry point takes the same [Mutex] → no races, the same guarantee
 * the iOS side gets from an `actor`.
 *
 * On-disk protection: these files carry logs and a screenshot, so they live in the app's
 * private cache directory, which is covered by file-based encryption on every device
 * Collie supports (minSdk 26). That is the platform's equivalent of the
 * `completeFileProtection` the iOS queue asks for.
 */
internal class UploadQueue(
    private val configuration: CollieConfiguration,
    private val transport: ReportTransport,
    private val directory: File,
) {

    /**
     * A pending report envelope stored on disk.
     *
     * Both screenshot fields are written and both are optional on the way back in, because
     * the file outlives the build that wrote it: a report queued while the tester was off
     * VPN is read back by whatever version of the app is installed when the connection
     * returns.
     */
    private data class Envelope(
        val id: String,
        var attempt: Int,
        val createdAtMillis: Long,
        var nextAttemptAtMillis: Long,
        /**
         * How many `<id>.screenshot.<index>` files this envelope has, or `null` on a file
         * left by a build that predates multiple screenshots.
         */
        val screenshotCount: Int?,
        /**
         * Written by every build. Pre-multi-screenshot ones wrote *only* this, alongside a
         * single unsuffixed `<id>.screenshot` file.
         */
        val hasScreenshot: Boolean = (screenshotCount ?: 0) > 0,
    ) {
        /** How many screenshot files to expect. An older envelope's `true` means one. */
        val screenshots: Int get() = screenshotCount ?: if (hasScreenshot) 1 else 0

        /**
         * Were the files written under the old, unsuffixed name? Only the absence of
         * `screenshotCount` says so — the flag alone cannot tell the two shapes apart.
         */
        val usesLegacyScreenshotName: Boolean get() = screenshotCount == null

        fun toJson(): String = JSONObject()
            .put("id", id)
            .put("attempt", attempt)
            .put("createdAt", createdAtMillis)
            .put("nextAttemptAt", nextAttemptAtMillis)
            .put("hasScreenshot", hasScreenshot)
            // Only when this envelope HAS a count. A legacy one is rewritten on every failed
            // retry, and writing a count it never had would flip it onto the indexed file
            // names — which its screenshot, sitting under the old unsuffixed name, does not
            // have. The image would vanish on the next attempt.
            .apply { screenshotCount?.let { put("screenshotCount", it) } }
            .toString()

        companion object {
            fun fromJson(raw: String): Envelope? = runCatching {
                val json = JSONObject(raw)
                Envelope(
                    id = json.getString("id"),
                    attempt = json.getInt("attempt"),
                    createdAtMillis = json.getLong("createdAt"),
                    nextAttemptAtMillis = json.getLong("nextAttemptAt"),
                    screenshotCount = if (json.has("screenshotCount")) {
                        json.getInt("screenshotCount")
                    } else {
                        null
                    },
                    hasScreenshot = json.optBoolean("hasScreenshot", false),
                )
            }.getOrNull()
        }
    }

    private sealed interface StepOutcome {
        data class Done(val reportId: String) : StepOutcome
        data class Rejected(val reason: String) : StepOutcome
        data class Transient(val reason: String) : StepOutcome
    }

    private val mutex = Mutex()
    private var isDraining = false

    init {
        directory.mkdirs()
    }

    private fun diag(message: String) {
        configuration.diagnostics?.invoke("[Collie] $message")
    }

    // MARK: - Public

    /**
     * Tries to send a report immediately.
     * - Transient failure → the report is queued to disk, [CollieSubmitOutcome.Queued].
     * - Permanent failure → [CollieSubmitOutcome.Rejected] (not written to disk — the same
     *   error would just repeat).
     */
    internal suspend fun submit(
        reportBody: ByteArray,
        screenshots: List<ByteArray>,
    ): CollieSubmitOutcome {
        val images = screenshots.filter { it.isNotEmpty() }
        val envelope = Envelope(
            id = UUID.randomUUID().toString(),
            attempt = 0,
            createdAtMillis = System.currentTimeMillis(),
            nextAttemptAtMillis = System.currentTimeMillis(),
            screenshotCount = images.size,
        )

        return when (val outcome = perform(envelope, reportBody, images)) {
            is StepOutcome.Done -> CollieSubmitOutcome.Sent(outcome.reportId)

            is StepOutcome.Rejected -> {
                diag("Report rejected by the backend with a permanent error: ${outcome.reason}")
                CollieSubmitOutcome.Rejected(outcome.reason)
            }

            is StepOutcome.Transient -> {
                diag("Report could not be sent, queued: ${outcome.reason}")
                envelope.nextAttemptAtMillis =
                    System.currentTimeMillis() + configuration.baseRetryDelayMillis
                mutex.withLock { persist(envelope, reportBody, images) }
                CollieSubmitOutcome.Queued
            }
        }
    }

    /**
     * Tries to send all pending reports on disk (the ones whose time has come), in order.
     * Idempotent: returns early if already running.
     */
    internal suspend fun drain(retainTransientFailures: Boolean = false) {
        mutex.withLock {
            if (isDraining) return
            isDraining = true
        }
        try {
            val envelopes = loadEnvelopes().sortedBy { it.createdAtMillis }
            for (envelope in envelopes) {
                val now = System.currentTimeMillis()

                // TTL: reports past the maximum age are deleted unsent (stale sensitive data).
                if (now - envelope.createdAtMillis > MAX_ENVELOPE_AGE_MILLIS) {
                    diag("Report expired (TTL), deleted without sending.")
                    remove(envelope)
                    continue
                }
                if (envelope.nextAttemptAtMillis > now) continue

                val reportBody = readFile(envelope.id, FileKind.REPORT)
                if (reportBody == null) {
                    remove(envelope)
                    continue
                }
                val screenshots = readScreenshots(envelope)

                when (val outcome = perform(envelope, reportBody, screenshots)) {
                    is StepOutcome.Done -> {
                        diag("Queued report sent: ${outcome.reportId}")
                        remove(envelope)
                    }

                    is StepOutcome.Rejected -> {
                        diag("Queued report dropped with a permanent error: ${outcome.reason}")
                        remove(envelope)
                    }

                    is StepOutcome.Transient -> {
                        envelope.attempt += 1
                        if (!retainTransientFailures &&
                            envelope.attempt > configuration.maxRetryCount
                        ) {
                            diag("Report exceeded the retry limit, dropped.")
                            remove(envelope)
                        } else {
                            // WorkManager owns the long-lived retry schedule. Cap the queue's
                            // own exponent so repeated background runs cannot overflow while the
                            // report is retained until its TTL.
                            val backoffAttempt = minOf(
                                envelope.attempt,
                                configuration.maxRetryCount,
                            )
                            val delay =
                                configuration.baseRetryDelayMillis * 2.0.pow(backoffAttempt)
                            envelope.nextAttemptAtMillis = System.currentTimeMillis() + delay.toLong()
                            writeEnvelope(envelope)
                        }
                    }
                }
            }
        } finally {
            mutex.withLock { isDraining = false }
        }
    }

    /**
     * Number of (non-expired) reports waiting in the queue (tests/diagnostics).
     * Expired envelopes are cleaned off disk during this call.
     */
    internal fun pendingCount(): Int {
        val now = System.currentTimeMillis()
        var live = 0
        for (envelope in loadEnvelopes()) {
            if (now - envelope.createdAtMillis > MAX_ENVELOPE_AGE_MILLIS) {
                remove(envelope)
            } else {
                live += 1
            }
        }
        return live
    }

    // MARK: - Single step (upload)

    /**
     * Uploads the report. The envelope id travels as the idempotency key, so a repeat of
     * a request the server already accepted resolves to the same report.
     */
    private suspend fun perform(
        envelope: Envelope,
        reportBody: ByteArray,
        screenshots: List<ByteArray>,
    ): StepOutcome {
        val result = withTimeoutOrNull(configuration.requestTimeoutMillis) {
            transport.upload(
                reportId = envelope.id,
                envelope = reportBody,
                screenshots = screenshots,
            )
        } ?: CollieOperationResult.TransientFailure(
            "Upload timed out after ${configuration.requestTimeoutMillis} ms",
        )

        return when (result) {
            is CollieOperationResult.Success -> StepOutcome.Done(result.value)
            is CollieOperationResult.PermanentFailure -> StepOutcome.Rejected(result.reason)
            is CollieOperationResult.TransientFailure -> StepOutcome.Transient(result.reason)
        }
    }

    // MARK: - Disk

    private enum class FileKind(val extension: String) {
        REPORT("report"),

        /**
         * The single unsuffixed name written before a report could carry several images.
         * Still read and still deleted — a queue file survives the app update that changed
         * the naming.
         */
        LEGACY_SCREENSHOT("screenshot"),
    }

    private fun file(id: String, kind: FileKind) = File(directory, "$id.${kind.extension}")

    private fun screenshotFile(id: String, index: Int) = File(directory, "$id.screenshot.$index")

    private fun envelopeFile(id: String) = File(directory, "$id.json")

    private fun persist(envelope: Envelope, reportBody: ByteArray, screenshots: List<ByteArray>) {
        val written = runCatching {
            file(envelope.id, FileKind.REPORT).writeBytes(reportBody)
            screenshots.forEachIndexed { index, screenshot ->
                screenshotFile(envelope.id, index).writeBytes(screenshot)
            }
        }.isSuccess

        if (!written) {
            remove(envelope)
            return
        }
        writeEnvelope(envelope)
    }

    private fun writeEnvelope(envelope: Envelope) {
        runCatching { envelopeFile(envelope.id).writeText(envelope.toJson()) }
    }

    private fun readFile(id: String, kind: FileKind): ByteArray? =
        runCatching { file(id, kind).takeIf { it.exists() }?.readBytes() }.getOrNull()

    /**
     * Reads the queued screenshots back in the order they were persisted.
     *
     * A file that has gone missing is skipped rather than aborting the report: the tester's
     * words and the log stream are worth more than one image, and the transport is told how
     * many it actually got.
     */
    private fun readScreenshots(envelope: Envelope): List<ByteArray> {
        val count = envelope.screenshots
        if (count <= 0) return emptyList()
        if (envelope.usesLegacyScreenshotName) {
            return listOfNotNull(readFile(envelope.id, FileKind.LEGACY_SCREENSHOT))
        }
        return (0 until count).mapNotNull { index ->
            runCatching {
                screenshotFile(envelope.id, index).takeIf { it.exists() }?.readBytes()
            }.getOrNull()
        }
    }

    private fun remove(envelope: Envelope) {
        runCatching { envelopeFile(envelope.id).delete() }
        // The legacy name too: an envelope written by an older build points at it, and a
        // partially written newer one can have more files than its count admits. Sweeping
        // the whole slot range is a handful of deletes against a leaked screenshot sitting
        // in the cache directory until the OS reclaims it.
        FileKind.entries.forEach { kind -> runCatching { file(envelope.id, kind).delete() } }
        val slots = maxOf(envelope.screenshots, CollieConfiguration.MAX_SCREENSHOTS_LIMIT)
        for (index in 0 until slots) {
            runCatching { screenshotFile(envelope.id, index).delete() }
        }
    }

    private fun loadEnvelopes(): List<Envelope> =
        directory.listFiles { file -> file.extension == "json" }
            ?.mapNotNull { file -> runCatching { file.readText() }.getOrNull()?.let(Envelope::fromJson) }
            ?: emptyList()

    internal companion object {
        /**
         * Maximum age of a report waiting in the queue. Older reports are deleted without
         * being sent (so stale sensitive data does not sit on disk indefinitely).
         */
        internal const val MAX_ENVELOPE_AGE_MILLIS: Long = 48L * 60 * 60 * 1000  // 48 hours

        /** The queue's directory inside the host's cache dir. */
        internal fun defaultDirectory(cacheDir: File): File = File(cacheDir, "collie/uploads")
    }
}
