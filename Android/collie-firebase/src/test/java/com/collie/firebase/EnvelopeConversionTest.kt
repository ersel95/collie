package com.collie.firebase

import com.collie.firebase.FirestoreTransport.Companion.toFirestoreMap
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The envelope is decoded into maps and lists so Firestore stores queryable data rather than a
 * blob. That conversion is the one place a report can be lost in full: a throw here is a
 * *permanent* failure, so the queue drops the report and the tester's words are gone.
 *
 * It has already happened once — `buildList { … get(index) … }` resolved `get` to the list's own
 * accessor instead of the JSONArray's, and every report died with
 * `IndexOutOfBoundsException: index: 0, size: 0`. Hence a test for a pure function.
 */
class EnvelopeConversionTest {

    private val envelope = """
        {
          "app": { "bundleId": "com.example.app", "version": "1.0", "build": "7" },
          "device": { "id": "abc", "name": "Ersel" },
          "report": { "whatHappened": "404 on the posts screen" },
          "entries": [
            { "date": "2026-07-29T06:45:00Z", "level": "info", "category": "app",
              "message": "started", "metadata": {} },
            { "date": "2026-07-29T06:45:01Z", "level": "error", "category": "network",
              "message": "GET /posts", "metadata": { "status": "404", "reqH.Accept": "*/*" } }
          ],
          "telemetry": { "networkType": "wifi", "batteryLevel": 82 }
        }
    """.trimIndent()

    @Test
    fun `every section survives the conversion`() {
        val document = JSONObject(envelope).toFirestoreMap()

        assertEquals(setOf("app", "device", "report", "entries", "telemetry"), document.keys)
        assertEquals("com.example.app", (document["app"] as Map<*, *>)["bundleId"])
        assertEquals("404 on the posts screen", (document["report"] as Map<*, *>)["whatHappened"])
    }

    @Test
    fun `the entries array becomes a list of maps, in order and lossless`() {
        val document = JSONObject(envelope).toFirestoreMap()
        val entries = document["entries"] as List<*>

        // The regression: this used to come back empty — or rather, it threw before it could.
        assertEquals(2, entries.size)
        assertEquals("app", (entries[0] as Map<*, *>)["category"])
        assertEquals("network", (entries[1] as Map<*, *>)["category"])

        val metadata = (entries[1] as Map<*, *>)["metadata"] as Map<*, *>
        assertEquals("404", metadata["status"])
        assertEquals("*/*", metadata["reqH.Accept"])
    }

    @Test
    fun `nested arrays are converted too`() {
        val document = JSONObject("""{ "a": [[1, 2], [3]] }""").toFirestoreMap()
        val outer = document["a"] as List<*>

        assertEquals(2, outer.size)
        assertEquals(listOf(1, 2), outer[0])
        assertEquals(listOf(3), outer[1])
    }

    @Test
    fun `json nulls are dropped rather than stored`() {
        // Firestore would happily store a null; the panel would then have to special-case it.
        val document = JSONObject("""{ "kept": "yes", "dropped": null }""").toFirestoreMap()

        assertEquals("yes", document["kept"])
        assertFalse(document.containsKey("dropped"))
    }
}
