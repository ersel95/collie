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
    /** Byte limit for **one** screenshot, not for all of them together. */
    public val maxScreenshotBytes: Int? = null,
    /**
     * How many screenshots a report may carry. Clamped to
     * [CollieConfiguration.MAX_SCREENSHOTS_LIMIT] before it is used — the panel cannot
     * display more than that whatever the server says.
     */
    public val maxScreenshots: Int? = null,
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
     * Uploads one report (JSON envelope + its screenshots); returns the server's report id
     * on success.
     *
     * @param reportId Client-generated idempotency key. Retrying with the same value
     *   must not create a second report server-side.
     * @param screenshots Zero to [CollieConfiguration.MAX_SCREENSHOTS_LIMIT] JPEGs, in the
     *   order the tester arranged them. Empty when the report carries no image.
     */
    public suspend fun upload(
        reportId: String,
        envelope: ByteArray,
        screenshots: List<ByteArray>,
    ): CollieOperationResult<String>

    /**
     * Fetches the server-side kill switch. `null` when it could not be reached — the
     * caller decides how to treat that (Collie fails *open* here, see [BugReportService]).
     */
    public suspend fun fetchRemoteConfig(): CollieRemoteConfig?

    /**
     * The largest a single screenshot may be for **this destination**, when the destination
     * has a hard limit of its own. `null` (the default) means it has none worth declaring —
     * an HTTPS backend enforces its own and answers 413.
     *
     * Without this the two limits do not know about each other, and that is not theoretical:
     * [CollieConfiguration.maxScreenshotBytes] defaults to 4 MB, `FirestoreTransport` stores
     * at most 650 KB — so the form compressed a photo to fit the first and the transport then
     * **dropped** it for exceeding the second. Shake captures are small enough to hide it; the
     * first image picked from a gallery is not.
     *
     * [BugReportService.maxScreenshotBytes] takes the strictest of local config, server value
     * and this, so compression aims at a size the destination will actually accept.
     */
    public val maxScreenshotBytes: Int? get() = null
}
