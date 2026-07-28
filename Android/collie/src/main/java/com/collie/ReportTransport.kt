package com.collie

/** Result of a single backend call. */
public sealed interface CollieOperationResult<out T> {
    /** Success (2xx). */
    public data class Success<T>(public val value: T) : CollieOperationResult<T>

    /** Permanent failure (auth/validation/too large). Must not be retried. */
    public data class PermanentFailure(public val reason: String) : CollieOperationResult<Nothing>

    /**
     * Transient failure (network / no VPN / 5xx / 408 / 429). Should be queued and
     * retried with backoff.
     */
    public data class TransientFailure(public val reason: String) : CollieOperationResult<Nothing>
}

/**
 * Server-side switches fetched at startup. The kill switch lets the backend turn the
 * reporter off for an app without shipping a new build.
 */
public data class CollieRemoteConfig(
    public val captureEnabled: Boolean,
    public val maxScreenshotBytes: Int? = null,
)

/**
 * Where a report goes once the form is submitted.
 *
 * Collie ships one implementation ([IngestionClient], a plain HTTPS upload) and the
 * `collie-firebase` artifact adds another (`FirestoreTransport`). Hosts whose network
 * policy only allows certain destinations — a banking app that may talk to Firebase and
 * its own API, but nowhere else — pick the transport that fits and pass it to
 * `Collie.configure(context, configuration, transport)`.
 *
 * The queue owns retries, disk persistence and backoff, so an implementation only has
 * to perform ONE attempt and classify the outcome:
 * - [CollieOperationResult.PermanentFailure] — the same call would fail again (auth,
 *   validation, too large).
 * - [CollieOperationResult.TransientFailure] — worth retrying later (offline, 5xx, timeout).
 */
public interface ReportTransport {

    /**
     * Uploads one report (JSON envelope + optional screenshot); returns the server's
     * report id on success.
     *
     * @param reportId Client-generated idempotency key. Retrying with the same value
     *   must not create a second report server-side.
     */
    public suspend fun upload(
        reportId: String,
        envelope: ByteArray,
        screenshot: ByteArray?,
    ): CollieOperationResult<String>

    /**
     * Fetches the server-side kill switch. `null` when it could not be reached — the
     * caller decides how to treat that (Collie fails *open* here, see [BugReportService]).
     */
    public suspend fun fetchRemoteConfig(): CollieRemoteConfig?
}
