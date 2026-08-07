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

    /** A pending report envelope stored on disk. */
    private data class Envelope(
        val id: String,
        var attempt: Int,
        val createdAtMillis: Long,
        var nextAttemptAtMillis: Long,
        val hasScreenshot: Boolean,
    ) {
        fun toJson(): String = JSONObject()
            .put("id", id)
            .put("attempt", attempt)
            .put("createdAt", createdAtMillis)
            .put("nextAttemptAt", nextAttemptAtMillis)
            .put("hasScreenshot", hasScreenshot)
            .toString()

        companion object {
            fun fromJson(raw: String): Envelope? = runCatching {
                val json = JSONObject(raw)
                Envelope(
                    id = json.getString("id"),
                    attempt = json.getInt("attempt"),
                    createdAtMillis = json.getLong("createdAt"),
                    nextAttemptAtMillis = json.getLong("nextAttemptAt"),
                    hasScreenshot = json.getBoolean("hasScreenshot"),
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
    internal suspend fun submit(reportBody: ByteArray, screenshot: ByteArray?): CollieSubmitOutcome {
        val envelope = Envelope(
            id = UUID.randomUUID().toString(),
            attempt = 0,
            createdAtMillis = System.currentTimeMillis(),
            nextAttemptAtMillis = System.currentTimeMillis(),
            hasScreenshot = screenshot != null && screenshot.isNotEmpty(),
        )

        return when (val outcome = perform(envelope, reportBody, screenshot)) {
            is StepOutcome.Done -> CollieSubmitOutcome.Sent(outcome.reportId)

            is StepOutcome.Rejected -> {
                diag("Report rejected by the backend with a permanent error: ${outcome.reason}")
                CollieSubmitOutcome.Rejected(outcome.reason)
            }

            is StepOutcome.Transient -> {
                diag("Report could not be sent, queued: ${outcome.reason}")
                envelope.nextAttemptAtMillis =
                    System.currentTimeMillis() + configuration.baseRetryDelayMillis
                mutex.withLock { persist(envelope, reportBody, screenshot) }
                CollieSubmitOutcome.Queued
            }
        }
    }

    /**
     * Tries to send all pending reports on disk (the ones whose time has come), in order.
     * Idempotent: returns early if already running.
     */
    internal suspend fun drain() {
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
                val screenshot = if (envelope.hasScreenshot) {
                    readFile(envelope.id, FileKind.SCREENSHOT)
                } else {
                    null
                }

                when (val outcome = perform(envelope, reportBody, screenshot)) {
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
                        if (envelope.attempt > configuration.maxRetryCount) {
                            diag("Report exceeded the retry limit, dropped.")
                            remove(envelope)
                        } else {
                            val delay =
                                configuration.baseRetryDelayMillis * 2.0.pow(envelope.attempt)
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
        screenshot: ByteArray?,
    ): StepOutcome {
        val result = withTimeoutOrNull(configuration.requestTimeoutMillis) {
            transport.upload(
                reportId = envelope.id,
                envelope = reportBody,
                screenshot = screenshot,
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
        SCREENSHOT("screenshot"),
    }

    private fun file(id: String, kind: FileKind) = File(directory, "$id.${kind.extension}")

    private fun envelopeFile(id: String) = File(directory, "$id.json")

    private fun persist(envelope: Envelope, reportBody: ByteArray, screenshot: ByteArray?) {
        val written = runCatching {
            file(envelope.id, FileKind.REPORT).writeBytes(reportBody)
            if (envelope.hasScreenshot && screenshot != null) {
                file(envelope.id, FileKind.SCREENSHOT).writeBytes(screenshot)
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

    private fun remove(envelope: Envelope) {
        runCatching { envelopeFile(envelope.id).delete() }
        FileKind.entries.forEach { kind -> runCatching { file(envelope.id, kind).delete() } }
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
