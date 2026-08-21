package com.collie

import com.collie.internal.CollieSessionTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The markers that put a report's pictures on the log timeline.
 *
 * A report can carry five images taken minutes apart, and without these the analyst sees a row
 * of screenshots with no idea which screen came first — while the stream beside them is
 * timestamped to the second. Mirrors `ScreenshotEventTests.swift`; the wording is shared,
 * because one panel reads both platforms.
 */
class CollieScreenshotEventTest {

    private val base = 1_700_000_000_000L

    @Test
    fun `each image gets a marker numbered by its position in the report`() {
        val markers = CollieScreenshotEvent.markerEntries(
            listOf(
                CollieScreenshotEvent(base, CollieScreenshotEvent.Source.CAPTURED),
                CollieScreenshotEvent(base + 30_000, CollieScreenshotEvent.Source.CAPTURED),
            ),
        )

        assertEquals(
            listOf("Screenshot 1 captured", "Screenshot 2 captured"),
            markers.map { it.message },
        )
        assertEquals(listOf("collie", "collie"), markers.map { it.category })
        assertEquals(listOf(base, base + 30_000), markers.map { it.epochMillis })
        assertEquals("1", markers.first().metadata["screenshot"])
    }

    /**
     * A gallery image was taken at some earlier, unknown time — saying it was "captured" then
     * would point the analyst at a moment in the stream that has nothing to do with it.
     */
    @Test
    fun `a gallery image says it was attached`() {
        val markers = CollieScreenshotEvent.markerEntries(
            listOf(CollieScreenshotEvent(base, CollieScreenshotEvent.Source.GALLERY)),
        )

        assertEquals("Screenshot 1 attached from the photo library", markers.first().message)
        assertEquals("library", markers.first().metadata["source"])
    }

    @Test
    fun `no images means no markers`() {
        assertTrue(CollieScreenshotEvent.markerEntries(emptyList()).isEmpty())
    }

    /**
     * The markers have to land where they happened, not at the end of the stream: the whole
     * point is reading "screenshot 2 was taken right after this request failed".
     */
    @Test
    fun `markers merge into the stream at their own timestamps`() {
        val host = listOf(
            CollieLogEntry(base + 10_000, "info", "app", "first"),
            CollieLogEntry(base + 100_000, "info", "app", "second"),
        )
        val markers = CollieScreenshotEvent.markerEntries(
            listOf(CollieScreenshotEvent(base + 50_000, CollieScreenshotEvent.Source.CAPTURED)),
        )

        val merged = CollieSessionTracker.merge(hostEntries = host, markers = markers)

        assertEquals(
            listOf("first", "Screenshot 1 captured", "second"),
            merged.map { it.message },
        )
    }
}
