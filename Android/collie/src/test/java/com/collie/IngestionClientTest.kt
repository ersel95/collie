package com.collie

import com.collie.internal.IngestionClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The status-code classification decides whether a failed report is retried for two days
 * or dropped on the spot, so it is locked in here exactly as it is in
 * `IngestionClientTests.swift`.
 *
 * The multipart body itself is OkHttp's, not Collie's, so it needs no test of its own —
 * the iOS suite tests hand-rolled boundary construction that has no counterpart here.
 */
class IngestionClientTest {

    @Test
    fun `2xx is a success`() {
        listOf(200, 201, 202, 299).forEach { code ->
            assertTrue(
                "HTTP $code should be a success",
                IngestionClient.classify(code, "") is CollieOperationResult.Success,
            )
        }
    }

    @Test
    fun `auth failures are permanent`() {
        listOf(401, 403).forEach { code ->
            val result = IngestionClient.classify(code, "")
            assertTrue(result is CollieOperationResult.PermanentFailure)
            assertTrue(
                (result as CollieOperationResult.PermanentFailure).reason.contains("api-key"),
            )
        }
    }

    @Test
    fun `timeout and rate limiting are transient`() {
        listOf(408, 429).forEach { code ->
            assertTrue(
                IngestionClient.classify(code, "") is CollieOperationResult.TransientFailure,
            )
        }
    }

    @Test
    fun `payload too large is permanent`() {
        val result = IngestionClient.classify(413, "")
        assertTrue(result is CollieOperationResult.PermanentFailure)
        assertTrue((result as CollieOperationResult.PermanentFailure).reason.contains("too large"))
    }

    @Test
    fun `other client errors are permanent and carry a snippet`() {
        val result = IngestionClient.classify(400, """{"error":"whatHappened is required"}""")
        assertTrue(result is CollieOperationResult.PermanentFailure)
        assertTrue(
            (result as CollieOperationResult.PermanentFailure).reason
                .contains("whatHappened is required"),
        )
    }

    @Test
    fun `server errors are transient`() {
        listOf(500, 502, 503).forEach { code ->
            assertTrue(
                IngestionClient.classify(code, "") is CollieOperationResult.TransientFailure,
            )
        }
    }

    @Test
    fun `an error snippet is capped so a whole html page cannot land in a log line`() {
        val result = IngestionClient.classify(400, "x".repeat(5_000))
        val reason = (result as CollieOperationResult.PermanentFailure).reason
        assertEquals("HTTP 400: ".length + 300, reason.length)
    }
}
