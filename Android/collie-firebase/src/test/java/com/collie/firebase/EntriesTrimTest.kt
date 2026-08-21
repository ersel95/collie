package com.collie.firebase

import com.collie.firebase.FirestoreTransport.Companion.trimEntries
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The report that triggered this: an envelope of 1.003.443 bytes was rejected outright, so the
 * tester's words, the screenshot and the whole stream were lost — even though the part that
 * would have been written to the report document was a few kilobytes.
 *
 * The iOS `FirestoreTransportTrimTests` cover the same cases; the two must agree, because a
 * report is the same document whichever device filed it.
 */
class EntriesTrimTest {

    /** One log entry, padded to roughly [bytes] so a budget can be expressed in whole entries. */
    private fun entry(index: Int, bytes: Int = 1_000): JSONObject = JSONObject().apply {
        put("date", "2026-08-18T12:00:%02dZ".format(index % 60))
        put("level", "info")
        put("category", "network")
        put("message", "entry $index")
        put("metadata", JSONObject().apply { put("responseBody", "x".repeat(bytes)) })
    }

    private fun stream(count: Int): JSONArray =
        JSONArray().apply { (0 until count).forEach { put(entry(it)) } }

    private fun messageAt(array: JSONArray, index: Int): String =
        array.getJSONObject(index).getString("message")

    @Test
    fun `a stream within budget is returned unchanged`() {
        val entries = stream(5)

        val result = trimEntries(entries, budget = 900_000)

        assertEquals(0, result.dropped)
        assertEquals(5, result.value.length())
        assertEquals("entry 0", messageAt(result.value, 0))
    }

    @Test
    fun `trimming keeps the newest entries and drops the oldest`() {
        val entries = stream(100)

        val result = trimEntries(entries, budget = 20_000)

        assertTrue(result.dropped > 0)
        // The marker heads the stream; everything after it is the tail of the original.
        assertEquals(100 - result.dropped + 1, result.value.length())
        assertEquals("entry ${result.dropped}", messageAt(result.value, 1))
        assertEquals("entry 99", messageAt(result.value, result.value.length() - 1))
    }

    @Test
    fun `a trimmed stream fits the budget`() {
        val budget = 20_000

        val result = trimEntries(stream(100), budget = budget)

        assertTrue(result.value.toString().toByteArray(Charsets.UTF_8).size <= budget)
    }

    @Test
    fun `the marker entry records what was dropped`() {
        val result = trimEntries(stream(100), budget = 20_000)

        val marker = result.value.getJSONObject(0)
        assertEquals("collie", marker.getString("category"))
        assertEquals("warning", marker.getString("level"))
        assertTrue(marker.getString("message").contains("${result.dropped}"))
        assertEquals(
            result.dropped.toString(),
            marker.getJSONObject("metadata").getString("droppedEntries"),
        )
    }

    /**
     * The panel places its session fold by comparing timestamps, so a marker stamped "now"
     * would jump the timeline. It carries the timestamp of the cut instead.
     */
    @Test
    fun `the marker carries the timestamp of the cut`() {
        val result = trimEntries(stream(100), budget = 20_000)

        assertEquals(
            result.value.getJSONObject(1).getString("date"),
            result.value.getJSONObject(0).getString("date"),
        )
    }

    /**
     * A budget smaller than a single entry still yields a writable document rather than a
     * failure: the marker alone tells the analyst the stream did not fit.
     */
    @Test
    fun `a budget too small for any entry keeps only the marker`() {
        val result = trimEntries(stream(10), budget = 100)

        assertEquals(10, result.dropped)
        assertEquals(1, result.value.length())
        assertEquals("collie", result.value.getJSONObject(0).getString("category"))
    }

    @Test
    fun `an empty stream is left alone`() {
        val result = trimEntries(JSONArray(), budget = 10)

        assertEquals(0, result.dropped)
        assertEquals(0, result.value.length())
    }

    /**
     * The regression itself: the report document is what the limit protects, and it is a
     * fraction of the envelope once the stream is lifted out.
     */
    @Test
    fun `the report document is measured without the stream`() {
        val envelope = JSONObject().apply {
            put("app", JSONObject().apply { put("bundleId", "com.example.app") })
            put(
                "report",
                JSONObject().apply { put("whatHappened", "Bununda rengi background success olmalı") },
            )
            put("entries", stream(1_000)) // ~1 MB, like the failing report
        }
        assertTrue(envelope.toString().toByteArray(Charsets.UTF_8).size > 900_000)

        envelope.remove("entries")

        assertTrue(envelope.toString().toByteArray(Charsets.UTF_8).size < 900_000)
    }

    // MARK: - Screenshot document ids

    /**
     * The id scheme is a contract with the panel, not an implementation detail: the panel
     * sees `screenshotCount: n` and reads exactly `<reportId>_0 … _<n-1>`. Change the
     * separator or the numbering base and every image disappears from the panel with no error
     * anywhere — which is precisely why it is pinned here, and why it must keep matching the
     * iOS SDK's `screenshotDocumentID`.
     */
    @Test
    fun `screenshot document ids are zero-based and underscore-suffixed`() {
        val reportId = "9F1C2B7A-0000-4000-8000-000000000001"
        assertEquals(
            listOf("${reportId}_0", "${reportId}_1", "${reportId}_2"),
            (0 until 3).map { FirestoreTransport.screenshotDocumentId(reportId, it) },
        )
    }
}
