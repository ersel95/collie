package com.collie.firebase

import android.util.Base64
import com.collie.CollieOperationResult
import com.collie.CollieRemoteConfig
import com.collie.ReportTransport
import com.google.android.gms.tasks.Task
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.SetOptions
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Sends reports to **Firebase** instead of an HTTPS endpoint of your own.
 *
 * This exists for hosts whose network policy allows Firebase but not arbitrary
 * destinations — a banking app that may reach `*.googleapis.com` and its own API, and
 * nothing else. The report lands in Firestore and the analyst panel picks it up from there.
 *
 * **Screenshots go to Firestore, not Cloud Storage.** Storage requires a paid Firebase
 * plan; on the free tier it is simply unavailable, which would strand every report at the
 * upload step. So the JPEG is base64-encoded into its *own* document — keeping it out of the
 * report document means listing reports in the panel never drags megabytes of image data
 * along. Firestore caps a document at 1 MiB, so [Configuration.maxScreenshotBytes] bounds the
 * raw JPEG well below that (base64 inflates by ~33%).
 *
 * **Idempotency.** The queue's report id becomes the Firestore *document id*, so a retry
 * after a lost response writes to the same document instead of creating a second report —
 * the same guarantee the HTTPS transport gets from its idempotency header.
 *
 * **The log stream goes to its own document, like the screenshot.** For the same reason: the
 * panel's list screen shows a status, a sentence, a device and a date, and Firestore's web
 * SDK cannot fetch a subset of a document's fields — asking for the report meant downloading
 * every log line and response body it carried. Testers do not close the app, so each report
 * also carries the previous ones' stream and the documents keep growing: the list got slower
 * with every report filed. `entries` therefore lands in `<entriesCollection>/<reportId>` and
 * the report document stays small.
 *
 * **What is written** (`<collection>/<reportId>`):
 * - `app`, `device`, `report`, `telemetry` — the envelope minus its stream, decoded from JSON
 *   so the data is queryable in Firestore rather than an opaque blob.
 * - `hasScreenshot` — whether `<screenshotCollection>/<reportId>` holds the image.
 * - `status` — always `"new"`; the panel owns the lifecycle afterwards.
 * - `createdAt` — server timestamp.
 *
 * **What is written** (`<entriesCollection>/<reportId>`): `appKey`, `entries`, `createdAt`.
 * `appKey` is repeated there so the security rules can scope the collection without reading
 * the parent document.
 *
 * The `entries` array is written **losslessly** wherever it lands: every category the host
 * logged is kept, exactly as the envelope builder produced it — and in the same shape the iOS
 * SDK writes, so one panel reads both platforms.
 */
public class FirestoreTransport @JvmOverloads constructor(
    private val configuration: Configuration,
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) : ReportTransport {

    /** Where reports and screenshots are written. */
    public data class Configuration(
        /** Which app the report belongs to — the panel groups by this. */
        public val appKey: String,
        /** Firestore collection that receives the reports. */
        public val collection: String = "collie_reports",
        /**
         * Firestore collection that receives the base64 screenshots, one document per
         * report. Kept separate so listing reports never pulls image data along.
         */
        public val screenshotCollection: String = "collie_report_screenshots",
        /**
         * Firestore collection that receives the raw log stream, one document per report.
         * Separate for the same reason as the screenshot: the panel lists reports without
         * it, and it is the part that grows without bound.
         */
        public val entriesCollection: String = "collie_report_entries",
        /**
         * Firestore document holding the remote kill switch
         * (`<configCollection>/<appKey>` with a boolean `captureEnabled`).
         */
        public val configCollection: String = "collie_config",
        /**
         * Upper bound on the REPORT document (Firestore's own hard limit is 1 MiB).
         * Measured after `entries` has been lifted out into its own document, because that
         * is what actually gets written here — measuring the whole envelope rejected reports
         * whose stream was never going to land in this document. Above this the report is a
         * permanent failure rather than retried forever.
         */
        public val maxDocumentBytes: Int = 900_000,
        /**
         * Upper bound on the RAW screenshot. base64 inflates by ~33%, so this must stay
         * comfortably under [maxDocumentBytes]. A larger image is dropped and the report
         * still goes — the text and logs matter more than the picture.
         */
        public val maxScreenshotBytes: Int = 650_000,
        /**
         * Upper bound on the LOG-STREAM document, which has its own 1 MiB ceiling. A stream
         * above this is trimmed (oldest entries first) rather than rejected — see
         * [trimEntries].
         */
        public val maxEntriesBytes: Int = 900_000,
    )

    // MARK: - ReportTransport

    override suspend fun upload(
        reportId: String,
        envelope: ByteArray,
        screenshot: ByteArray?,
    ): CollieOperationResult<String> {
        // A malformed envelope can never succeed — fail permanently so the queue drops it
        // instead of retrying for 48 hours.
        //
        // The stream comes out FIRST, before anything is measured or written: it goes to its
        // own document, so the report document's size must be judged without it. Measuring
        // the whole envelope instead rejected reports that would have fit perfectly well — a
        // long session's log stream is by far the largest part of an envelope, and none of it
        // lands in the document this limit protects.
        val json = runCatching {
            JSONObject(String(envelope, Charsets.UTF_8))
        }.getOrElse { error ->
            // Carry the reason: this is a permanent failure, so the queue drops the report and
            // the tester's words are gone — a bare "could not decode" leaves nothing to debug.
            return CollieOperationResult.PermanentFailure(
                "Could not decode the report envelope: ${error::class.java.simpleName}: ${error.message}",
            )
        }
        val rawEntries = json.remove("entries") as? JSONArray

        val documentBytes = json.toString().toByteArray(Charsets.UTF_8).size
        if (documentBytes > configuration.maxDocumentBytes) {
            return CollieOperationResult.PermanentFailure(
                "Report is too large for Firestore ($documentBytes bytes > " +
                    "${configuration.maxDocumentBytes})",
            )
        }

        val document = runCatching {
            json.toFirestoreMap()
        }.getOrElse { error ->
            return CollieOperationResult.PermanentFailure(
                "Could not decode the report envelope: ${error::class.java.simpleName}: ${error.message}",
            )
        }

        // 1. Screenshot first: if it fails transiently the whole report is retried, so the
        //    report document never claims an image that was never written.
        var hasScreenshot = false
        if (screenshot != null && screenshot.isNotEmpty()) {
            if (screenshot.size > configuration.maxScreenshotBytes) {
                document["screenshotError"] =
                    "Screenshot dropped: ${screenshot.size} bytes exceeds the " +
                    "${configuration.maxScreenshotBytes}-byte Firestore limit"
            } else {
                when (val result = putScreenshot(screenshot, reportId)) {
                    is CollieOperationResult.Success -> hasScreenshot = true
                    // Losing the image must not lose the report.
                    is CollieOperationResult.PermanentFailure ->
                        document["screenshotError"] = result.reason

                    is CollieOperationResult.TransientFailure ->
                        return CollieOperationResult.TransientFailure(result.reason)
                }
            }
        }

        // 2. The log stream, into its own document — the whole point of the split. Written
        //    BEFORE the report for the same reason the screenshot is: the report document is
        //    what the panel discovers, and it must never point at a stream that is not there
        //    yet.
        //
        //    A permanent failure falls back to the old shape rather than dropping the logs.
        //    Rules that predate this collection reject the write permanently, and a report
        //    whose stream was silently discarded is worse than a large document: the stream is
        //    what the analyst reads to reconstruct the bug. That fallback has to fit the report
        //    document's own budget, so the stream is trimmed a second time against whatever
        //    room is left beside the report's own fields.
        if (rawEntries != null) {
            val stream = trimEntries(rawEntries, budget = configuration.maxEntriesBytes)
            // Never trim silently: the marker entry says it inside the stream the analyst
            // reads, and this field says it on the report itself.
            if (stream.dropped > 0) document["entriesTrimmed"] = stream.dropped

            when (val result = putEntries(stream.value.toFirestoreList(), reportId)) {
                // The write below merges, so an `entries` field left by an EARLIER attempt
                // would survive it: a report queued by a build that wrote the stream inline
                // and retried after the app updated. Deleting the field keeps the report
                // document small in that case too, and the stream is already safely written.
                is CollieOperationResult.Success -> document["entries"] = FieldValue.delete()

                is CollieOperationResult.PermanentFailure -> {
                    // Trimmed from the ORIGINAL stream, not from the already-trimmed one: a
                    // second pass over its own output would drop the first marker and count
                    // it among the losses, so the report would report one entry more than it
                    // lost.
                    val inline = trimEntries(
                        rawEntries,
                        budget = configuration.maxDocumentBytes - documentBytes,
                    )
                    document["entries"] = inline.value.toFirestoreList()
                    if (inline.dropped > 0) {
                        document["entriesTrimmed"] = inline.dropped
                    } else {
                        document.remove("entriesTrimmed")
                    }
                }

                is CollieOperationResult.TransientFailure ->
                    return CollieOperationResult.TransientFailure(result.reason)
            }
        }

        document["appKey"] = configuration.appKey
        document["hasScreenshot"] = hasScreenshot
        document["status"] = "new"
        document["clientReportId"] = reportId
        document["createdAt"] = FieldValue.serverTimestamp()

        // 3. The report id IS the document id → a retry overwrites the same document rather
        //    than adding another one.
        return try {
            firestore.collection(configuration.collection)
                .document(reportId)
                .set(document, SetOptions.merge())
                .await()
            CollieOperationResult.Success(reportId)
        } catch (error: Exception) {
            classify(error, action = "write the report")
        }
    }

    override suspend fun fetchRemoteConfig(): CollieRemoteConfig? = try {
        val snapshot = firestore.collection(configuration.configCollection)
            .document(configuration.appKey)
            .get()
            .await()

        if (!snapshot.exists()) {
            // No config document yet → treat capture as on (fail-open), matching the HTTPS
            // transport's behaviour when the endpoint is unreachable.
            CollieRemoteConfig(captureEnabled = true)
        } else {
            CollieRemoteConfig(
                captureEnabled = snapshot.getBoolean("captureEnabled") ?: true,
                maxScreenshotBytes = snapshot.getLong("maxScreenshotBytes")?.toInt(),
            )
        }
    } catch (error: Exception) {
        // Unreachable → null, so BugReportService keeps the previous state.
        null
    }

    // MARK: - Screenshot

    /**
     * Writes the JPEG as base64 into its own document, keyed by the report id so a retry
     * overwrites rather than duplicates.
     */
    private suspend fun putScreenshot(
        data: ByteArray,
        reportId: String,
    ): CollieOperationResult<Unit> = try {
        firestore.collection(configuration.screenshotCollection)
            .document(reportId)
            .set(
                mapOf(
                    "appKey" to configuration.appKey,
                    "contentType" to "image/jpeg",
                    "byteSize" to data.size,
                    "data" to Base64.encodeToString(data, Base64.NO_WRAP),
                    "createdAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            )
            .await()
        CollieOperationResult.Success(Unit)
    } catch (error: Exception) {
        classify(error, action = "write the screenshot")
    }

    // MARK: - Log stream

    /**
     * Writes the raw log stream into its own document, keyed by the report id so a retry
     * overwrites rather than duplicates — the same idempotency the report document gets.
     *
     * `appKey` travels with it because the security rules scope this collection on its own; a
     * rule that had to read the parent report would both cost a read per write and fail on the
     * very first write, when the parent does not exist yet.
     */
    private suspend fun putEntries(
        entries: Any,
        reportId: String,
    ): CollieOperationResult<Unit> = try {
        firestore.collection(configuration.entriesCollection)
            .document(reportId)
            .set(
                mapOf(
                    "appKey" to configuration.appKey,
                    "entries" to entries,
                    "createdAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            )
            .await()
        CollieOperationResult.Success(Unit)
    } catch (error: Exception) {
        classify(error, action = "write the log entries")
    }

    // MARK: - Error classification

    internal companion object {

        // MARK: JSON → Firestore

        /**
         * Decodes the envelope into maps and lists so the data is queryable in Firestore, rather
         * than a string blob the panel would have to parse client-side.
         *
         * On the companion rather than the instance so it can be tested without a
         * `FirebaseFirestore` — the conversion is where a report is silently lost, and it needs
         * a test more than the network call does.
         */
        internal fun JSONObject.toFirestoreMap(): MutableMap<String, Any> {
            val result = mutableMapOf<String, Any>()
            keys().forEach { key ->
                when (val value = this.get(key)) {
                    is JSONObject -> result[key] = value.toFirestoreMap()
                    is JSONArray -> result[key] = value.toFirestoreList()
                    JSONObject.NULL -> Unit
                    else -> result[key] = value
                }
            }
            return result
        }

        // NOT `buildList { … get(index) … }`: inside that lambda `get` resolves to the *list's*
        // own accessor rather than the JSONArray's, so it reads index 0 of an empty list and
        // every report dies with IndexOutOfBoundsException. An explicit local keeps the
        // receiver honest.
        internal fun JSONArray.toFirestoreList(): List<Any> {
            val result = mutableListOf<Any>()
            for (index in 0 until length()) {
                when (val value = this.get(index)) {
                    is JSONObject -> result.add(value.toFirestoreMap())
                    is JSONArray -> result.add(value.toFirestoreList())
                    JSONObject.NULL -> Unit
                    else -> result.add(value)
                }
            }
            return result
        }
        /** A log stream after [trimEntries], and how many entries it lost. */
        internal data class TrimmedStream(val value: JSONArray, val dropped: Int)

        /** Room left for the marker entry that records what was dropped. */
        private const val TRIM_MARKER_RESERVE = 512

        /**
         * Trims the log stream to [budget] bytes by dropping the OLDEST entries first, and
         * prepends a marker entry saying how many went.
         *
         * Collie is lossless everywhere else, and that is deliberate: the panel derives its
         * network and navigation views from the raw stream. This is the one place a hard
         * platform limit overrides it. Firestore caps a document at 1 MiB, and the stream is
         * the part of a report that grows without bound — testers do not kill the app, so a
         * long session eventually carries more log than any document can hold. The choice
         * there is not "lossless or trimmed" but "trimmed or no report at all", tester's words
         * and screenshot included. So the tail survives: the entries nearest the bug are the
         * ones the analyst opened the report for.
         *
         * Must stay in step with the iOS implementation of the same name.
         */
        internal fun trimEntries(entries: JSONArray, budget: Int): TrimmedStream {
            val allowance = maxOf(0, budget - TRIM_MARKER_RESERVE)
            // `[` + `]`; each entry after the first also costs its separating comma.
            var used = 2
            var firstKept = entries.length()
            for (index in entries.length() - 1 downTo 0) {
                val size = entries.get(index).toString().toByteArray(Charsets.UTF_8).size
                val cost = size + 1
                if (used + cost > allowance) break
                used += cost
                firstKept = index
            }

            val dropped = firstKept
            if (dropped == 0) return TrimmedStream(entries, 0)

            val kept = JSONArray()
            kept.put(
                markerEntry(
                    dropped = dropped,
                    total = entries.length(),
                    // The panel places its session fold by comparing timestamps, so a marker
                    // stamped "now" would jump the timeline. It carries the timestamp of the
                    // cut instead.
                    date = timestampOf(entries.opt(firstKept)) ?: timestampOf(entries.opt(dropped - 1)),
                ),
            )
            for (index in firstKept until entries.length()) kept.put(entries.get(index))
            return TrimmedStream(kept, dropped)
        }

        private fun markerEntry(dropped: Int, total: Int, date: String?): JSONObject =
            JSONObject().apply {
                put("date", date ?: "")
                put("level", "warning")
                put("category", "collie")
                put(
                    "message",
                    "Log stream trimmed — the oldest $dropped of $total entries were dropped " +
                        "to fit Firestore's document limit.",
                )
                put("metadata", JSONObject().apply { put("droppedEntries", dropped.toString()) })
            }

        private fun timestampOf(entry: Any?): String? =
            (entry as? JSONObject)?.optString("date")?.takeIf { it.isNotEmpty() }

        /**
         * Maps Firestore errors onto the queue's retry policy. Permission/argument problems
         * repeat forever, so they are permanent; everything else is worth another attempt
         * once connectivity returns.
         */
        internal fun <T> classify(error: Exception, action: String): CollieOperationResult<T> {
            val message = "Could not $action: ${error.message ?: error::class.java.simpleName}"
            val code = (error as? FirebaseFirestoreException)?.code
                ?: return CollieOperationResult.TransientFailure(message)

            return when (code) {
                FirebaseFirestoreException.Code.PERMISSION_DENIED,
                FirebaseFirestoreException.Code.UNAUTHENTICATED,
                FirebaseFirestoreException.Code.INVALID_ARGUMENT,
                FirebaseFirestoreException.Code.FAILED_PRECONDITION,
                -> CollieOperationResult.PermanentFailure(message)

                else -> CollieOperationResult.TransientFailure(message)
            }
        }
    }
}

/**
 * Awaits a Play Services [Task] without pulling in `kotlinx-coroutines-play-services`: the
 * host pins its own coroutines and Play Services versions, and one fewer transitive
 * dependency is one fewer resolution conflict to explain. The continuation is cancellable so
 * the queue's request timeout can recover when Firestore keeps an offline write pending.
 */
internal suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { result ->
        if (continuation.isActive) continuation.resume(result)
    }
    addOnFailureListener { error ->
        if (continuation.isActive) continuation.resumeWithException(error)
    }
    addOnCanceledListener {
        if (continuation.isActive) {
            continuation.resumeWithException(
                FirebaseFirestoreException(
                    "The Firestore write was cancelled",
                    FirebaseFirestoreException.Code.CANCELLED,
                ),
            )
        }
    }
}
