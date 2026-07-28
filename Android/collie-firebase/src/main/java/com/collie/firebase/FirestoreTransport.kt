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
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

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
 * **What is written** (`<collection>/<reportId>`):
 * - `app`, `device`, `report`, `entries`, `telemetry` — the envelope, decoded from JSON so
 *   the data is queryable in Firestore rather than an opaque blob.
 * - `hasScreenshot` — whether `<screenshotCollection>/<reportId>` holds the image.
 * - `status` — always `"new"`; the panel owns the lifecycle afterwards.
 * - `createdAt` — server timestamp.
 *
 * The `entries` array is written **losslessly**: every category the host logged is kept,
 * exactly as the envelope builder produced it — and in the same shape the iOS SDK writes, so
 * one panel reads both platforms.
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
         * Firestore document holding the remote kill switch
         * (`<configCollection>/<appKey>` with a boolean `captureEnabled`).
         */
        public val configCollection: String = "collie_config",
        /**
         * Upper bound on a single Firestore document (Firestore's own hard limit is 1 MiB).
         * Envelopes above this are rejected as a permanent failure rather than retried
         * forever.
         */
        public val maxDocumentBytes: Int = 900_000,
        /**
         * Upper bound on the RAW screenshot. base64 inflates by ~33%, so this must stay
         * comfortably under [maxDocumentBytes]. A larger image is dropped and the report
         * still goes — the text and logs matter more than the picture.
         */
        public val maxScreenshotBytes: Int = 650_000,
    )

    // MARK: - ReportTransport

    override suspend fun upload(
        reportId: String,
        envelope: ByteArray,
        screenshot: ByteArray?,
    ): CollieOperationResult<String> {
        // A malformed or oversized envelope can never succeed — fail permanently so the
        // queue drops it instead of retrying for 48 hours.
        if (envelope.size > configuration.maxDocumentBytes) {
            return CollieOperationResult.PermanentFailure(
                "Report is too large for Firestore (${envelope.size} bytes > " +
                    "${configuration.maxDocumentBytes})",
            )
        }

        val document = runCatching {
            JSONObject(String(envelope, Charsets.UTF_8)).toFirestoreMap()
        }.getOrNull() ?: return CollieOperationResult.PermanentFailure(
            "Could not decode the report envelope",
        )

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

        document["appKey"] = configuration.appKey
        document["hasScreenshot"] = hasScreenshot
        document["status"] = "new"
        document["clientReportId"] = reportId
        document["createdAt"] = FieldValue.serverTimestamp()

        // 2. The report id IS the document id → a retry overwrites the same document rather
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

    // MARK: - JSON → Firestore

    /**
     * Decodes the envelope into maps and lists so the data is queryable in Firestore, rather
     * than a string blob the panel would have to parse client-side.
     */
    private fun JSONObject.toFirestoreMap(): MutableMap<String, Any> {
        val result = mutableMapOf<String, Any>()
        keys().forEach { key ->
            when (val value = get(key)) {
                is JSONObject -> result[key] = value.toFirestoreMap()
                is JSONArray -> result[key] = value.toFirestoreList()
                JSONObject.NULL -> Unit
                else -> result[key] = value
            }
        }
        return result
    }

    private fun JSONArray.toFirestoreList(): List<Any> = buildList {
        for (index in 0 until length()) {
            when (val value = get(index)) {
                is JSONObject -> add(value.toFirestoreMap())
                is JSONArray -> add(value.toFirestoreList())
                JSONObject.NULL -> Unit
                else -> add(value)
            }
        }
    }

    // MARK: - Error classification

    internal companion object {
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
 * dependency is one fewer resolution conflict to explain.
 */
private suspend fun <T> Task<T>.await(): T = suspendCoroutine { continuation ->
    addOnSuccessListener { result -> continuation.resume(result) }
    addOnFailureListener { error -> continuation.resumeWithException(error) }
    addOnCanceledListener {
        continuation.resumeWithException(
            FirebaseFirestoreException(
                "The Firestore write was cancelled",
                FirebaseFirestoreException.Code.CANCELLED,
            ),
        )
    }
}
