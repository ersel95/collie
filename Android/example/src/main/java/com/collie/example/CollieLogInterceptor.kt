package com.collie.example

import com.collie.CollieLogEntry
import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.util.ArrayDeque

/**
 * The log bridge. **This is the piece every host has to write**, and it is deliberately part
 * of the example rather than the SDK: Collie is log-source agnostic — it never depends on a
 * logging library, it asks the host for a snapshot at report time.
 *
 * Chucker and Collie answer different questions about the same traffic. Chucker shows a
 * developer what a request did, *now*, on the device. Collie has to put that same traffic in
 * front of an analyst *later*, in a report, next to the screenshot and the tester's sentence.
 * Neither can do the other's job, and Chucker exposes no API to read its store — so the
 * traffic is captured once here and handed to both.
 *
 * The metadata keys are Collie's documented convention. The panel derives its Network view
 * from them, so `method` / `url` / `status` / `durationMs` and the `reqH.` / `respH.` header
 * prefixes are not free-form: spell them differently and the report still uploads, but the
 * panel shows a bare log line instead of a request.
 */
class CollieLogInterceptor(
    /**
     * Collie's own endpoints, as **whole URLs**. A report is sent over HTTP like anything
     * else, so without this the act of reporting a bug would be logged into the next report —
     * and each report would carry the previous one's body.
     *
     * ⚠️ Collie also offers `configuration.captureExclusionFragments`, which is the host/path
     * pair as separate strings. Matching on those with `contains` is a trap, and this example
     * fell into it first: with `reportsPath = "/post"`, the fragment `/post` also matches this
     * app's own `GET /posts` — so every request the tester wanted reported was silently
     * dropped from the report. Whole-URL prefixes cannot misfire that way. Use the fragments
     * only where nothing finer is accepted (some capture tools take substrings only), and pick
     * a specific `reportsPath` when you do.
     */
    private val excludedUrlPrefixes: List<String> = emptyList(),
    private val maxEntries: Int = 500,
) : Interceptor {

    private val entries = ArrayDeque<CollieLogEntry>()
    private val lock = Any()

    /** What `CollieConfiguration.logSnapshotProvider` hands over at report time. */
    fun snapshot(): List<CollieLogEntry> = synchronized(lock) { entries.toList() }

    /** App-level lines (navigation, business events) share the timeline with the traffic. */
    fun log(
        level: String,
        category: String,
        message: String,
        metadata: Map<String, String> = emptyMap(),
    ) {
        record(
            CollieLogEntry(
                epochMillis = System.currentTimeMillis(),
                level = level,
                category = category,
                message = message,
                metadata = metadata,
            ),
        )
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val url = request.url.toString()

        if (excludedUrlPrefixes.any { url.startsWith(it, ignoreCase = true) }) {
            return chain.proceed(request)
        }

        val startedAt = System.currentTimeMillis()
        val response = try {
            chain.proceed(request)
        } catch (error: IOException) {
            // A failed call is exactly the kind a tester reports, so it must reach the report
            // too — with the error text where the status code would be.
            record(
                CollieLogEntry(
                    epochMillis = startedAt,
                    level = "error",
                    category = "network",
                    message = "${request.method} $url",
                    metadata = buildMap {
                        put("method", request.method)
                        put("url", url)
                        put("durationMs", (System.currentTimeMillis() - startedAt).toString())
                        put("error", error.message ?: error::class.java.simpleName)
                        putHeaders("reqH.", request.headers)
                    },
                ),
            )
            throw error
        }

        val durationMs = System.currentTimeMillis() - startedAt
        // `peekBody` copies without consuming, so the app still reads the response normally —
        // the same trick Chucker uses.
        val responseBody = runCatching {
            response.peekBody(MAX_BODY_BYTES).string()
        }.getOrNull()

        record(
            CollieLogEntry(
                epochMillis = startedAt,
                level = if (response.isSuccessful) "info" else "error",
                category = "network",
                message = "${request.method} $url",
                metadata = buildMap {
                    put("method", request.method)
                    put("url", url)
                    put("status", response.code.toString())
                    put("durationMs", durationMs.toString())
                    put("reqBytes", (request.body?.contentLength() ?: 0L).toString())
                    put("respBytes", (response.body?.contentLength() ?: -1L).toString())
                    responseBody?.takeIf { it.isNotBlank() }?.let { put("responseBody", it) }
                    putHeaders("reqH.", request.headers)
                    putHeaders("respH.", response.headers)
                },
            ),
        )
        return response
    }

    private fun MutableMap<String, String>.putHeaders(prefix: String, headers: okhttp3.Headers) {
        headers.forEach { (name, value) ->
            // Never let a credential travel into a report. Chucker redacts the same headers
            // through `redactHeaders(...)`; a bug report is read by more people than a
            // developer's device, so the bar here is at least as high.
            val redacted = name.lowercase() in REDACTED_HEADERS
            put("$prefix$name", if (redacted) "██ redacted" else value)
        }
    }

    private fun record(entry: CollieLogEntry) {
        synchronized(lock) {
            entries.addLast(entry)
            while (entries.size > maxEntries) entries.removeFirst()
        }
    }

    private companion object {
        const val MAX_BODY_BYTES = 100_000L
        val REDACTED_HEADERS = setOf("authorization", "cookie", "set-cookie", "x-collie-api-key")
    }
}
