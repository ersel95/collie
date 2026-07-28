package com.collie.internal

import com.collie.CollieConfiguration
import com.collie.CollieOperationResult
import com.collie.CollieRemoteConfig
import com.collie.ReportTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Collie backend client: one multipart POST per report.
 *
 * - **Its own [OkHttpClient]**, built here rather than taken from the host: none of the
 *   host's interceptors are attached, so a network-capture tool (Olaf, Chucker) never sees
 *   Collie's own traffic and cannot log a report about sending a report. (Additionally the
 *   host adds `captureExclusionFragments` to its capture exclude list — double safeguard.)
 *   This mirrors `protocolClasses = []` on the iOS `URLSession`.
 * - Auth: the `x-collie-api-key` header is the sole ingestion credential; it identifies
 *   the app and authenticates the caller.
 */
internal class IngestionClient(
    private val configuration: CollieConfiguration,
) : ReportTransport {

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(configuration.requestTimeoutMillis, TimeUnit.MILLISECONDS)
            .readTimeout(configuration.requestTimeoutMillis, TimeUnit.MILLISECONDS)
            .writeTimeout(configuration.requestTimeoutMillis, TimeUnit.MILLISECONDS)
            // No cache, no cookies, no interceptors — nothing of the host's is inherited.
            .build()
    }

    // MARK: - Report upload

    /**
     * `POST <reportsPath>` — multipart with a `report` JSON part and an optional
     * `screenshot` binary part. Part names are the backend contract.
     */
    override suspend fun upload(
        reportId: String,
        envelope: ByteArray,
        screenshot: ByteArray?,
    ): CollieOperationResult<String> {
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart(
                "report",
                "report.json",
                envelope.toRequestBody(JSON_MEDIA_TYPE),
            )
            .apply {
                if (screenshot != null && screenshot.isNotEmpty()) {
                    addFormDataPart(
                        "screenshot",
                        "screenshot.jpg",
                        screenshot.toRequestBody(JPEG_MEDIA_TYPE),
                    )
                }
            }
            .build()

        val request = Request.Builder()
            .url(configuration.reportsUrl)
            .post(body)
            .header(CollieConfiguration.API_KEY_HEADER, configuration.apiKey)
            .header("Accept", "application/json")
            // Duplicate prevention across retries: the server must treat a repeat of the same
            // key as the same report (a response lost in transit must not create a second one).
            .header(IDEMPOTENCY_HEADER, reportId)
            .build()

        return when (val result = perform(request)) {
            is CollieOperationResult.Success -> {
                // A 2xx without a parseable id still means the server accepted the report —
                // retrying would duplicate it, so fall back to the client id instead of failing.
                val serverId = runCatching {
                    JSONObject(result.value).getJSONObject("data").getString("reportId")
                }.getOrNull()
                CollieOperationResult.Success(serverId?.takeIf { it.isNotBlank() } ?: reportId)
            }

            is CollieOperationResult.PermanentFailure -> result
            is CollieOperationResult.TransientFailure -> result
        }
    }

    // MARK: - Remote config

    /**
     * `GET <configPath>` — the response is a bare object (no envelope), by contract with
     * the SDK.
     */
    override suspend fun fetchRemoteConfig(): CollieRemoteConfig? {
        val request = Request.Builder()
            .url(configuration.configUrl)
            .get()
            .header(CollieConfiguration.API_KEY_HEADER, configuration.apiKey)
            .header("Accept", "application/json")
            .build()

        val payload = when (val result = perform(request)) {
            is CollieOperationResult.Success -> result.value
            else -> return null
        }
        return runCatching {
            val json = JSONObject(payload)
            CollieRemoteConfig(
                captureEnabled = json.optBoolean("captureEnabled", true),
                maxScreenshotBytes = if (json.has("maxScreenshotBytes")) {
                    json.optInt("maxScreenshotBytes").takeIf { it > 0 }
                } else {
                    null
                },
            )
        }.getOrNull()
    }

    // MARK: - Shared request/classification

    private suspend fun perform(request: Request): CollieOperationResult<String> =
        withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute().use { response ->
                    classify(response.code, response.body?.string().orEmpty())
                }
            } catch (error: IOException) {
                // Corporate backends are often reachable only over VPN — the most likely cause.
                CollieOperationResult.TransientFailure(
                    "${error.message ?: error::class.java.simpleName} — the Collie backend may be " +
                        "unreachable (check your VPN connection)",
                )
            }
        }

    internal companion object {
        /** Header carrying the client-generated idempotency key. */
        internal const val IDEMPOTENCY_HEADER: String = "x-collie-idempotency-key"

        private val JSON_MEDIA_TYPE = "application/json".toMediaType()
        private val JPEG_MEDIA_TYPE = "image/jpeg".toMediaType()

        /**
         * Classifies an HTTP status code as permanent/transient.
         * 2xx success · 408/429 transient · other 4xx permanent (special messages for
         * 401/403 and 413) · 5xx transient.
         */
        internal fun classify(statusCode: Int, responseBody: String): CollieOperationResult<String> =
            when (statusCode) {
                in 200..299 -> CollieOperationResult.Success(responseBody)
                401, 403 -> CollieOperationResult.PermanentFailure(
                    "api-key is invalid or disabled ($statusCode)",
                )

                408, 429 -> CollieOperationResult.TransientFailure("HTTP $statusCode")
                413 -> CollieOperationResult.PermanentFailure("Report is too large (413)")
                in 400..499 -> CollieOperationResult.PermanentFailure(
                    "HTTP $statusCode${errorSnippet(responseBody)}",
                )

                else -> CollieOperationResult.TransientFailure("HTTP $statusCode")
            }

        /** Extracts a short, diagnosis-friendly snippet from an error body. */
        private fun errorSnippet(body: String): String {
            if (body.isEmpty()) return ""
            return ": " + body.replace("\n", " ").take(300)
        }
    }
}
