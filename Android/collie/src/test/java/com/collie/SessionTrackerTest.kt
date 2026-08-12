package com.collie

import com.collie.internal.CollieSessionTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The session context that lets the panel fold a report's repeated history: persistent
 * counters, logical session boundaries, and the markers that show where those boundaries fall
 * in the log stream.
 *
 * These mirror `SessionTrackerTests.swift`: the same tester behaviour must split into the same
 * sessions on both platforms, or the panel folds two reports of one scenario differently.
 */
class SessionTrackerTest {

    /** The persistent half, in memory — a unit test has no `SharedPreferences`. */
    private class FakeStore : CollieSessionTracker.Store {
        private val values = mutableMapOf<String, Long>()
        override fun readLong(key: String): Long? = values[key]
        override fun writeLong(key: String, value: Long) {
            values[key] = value
        }
    }

    private val store = FakeStore()

    private fun tracker(processStartedAtMillis: Long = 1_769_616_000_000) =
        CollieSessionTracker(store = store, processStartedAtMillis = processStartedAtMillis)

    // MARK: - Counters

    @Test
    fun `previous report at is the earlier report's captured at`() {
        val tracker = tracker()
        val first = tracker.stampForReport(1_769_616_100_000)
        val second = tracker.stampForReport(1_769_617_000_000)

        assertNull("the first report has no predecessor", first.previousReportAtMillis)
        assertEquals(1_769_616_100_000, second.previousReportAtMillis)
    }

    @Test
    fun `sequence starts at one and counts`() {
        val tracker = tracker()
        val sequences = (0 until 3).map { tracker.stampForReport(1_769_616_000_000 + it * 1_000L).sequence }
        assertEquals(listOf(1, 2, 3), sequences)
    }

    @Test
    fun `counters survive a process restart`() {
        // Killing the app must not make a tester's eleventh report look like their first: the
        // counters are persisted, `processStartedAt` is the one thing that resets.
        val firstProcess = tracker(processStartedAtMillis = 1_769_616_000_000)
        val before = firstProcess.stampForReport(1_769_616_500_000)

        val relaunchedAt = 1_769_700_000_000
        val secondProcess = tracker(processStartedAtMillis = relaunchedAt)
        val after = secondProcess.stampForReport(1_769_700_100_000)

        assertEquals(before.sequence + 1, after.sequence)
        assertEquals(before.sessionOrdinal + 1, after.sessionOrdinal)
        assertEquals(1_769_616_500_000, after.previousReportAtMillis)
        assertEquals(relaunchedAt, after.processStartedAtMillis)
        assertEquals(relaunchedAt, after.sessionStartedAtMillis)
    }

    // MARK: - Logical sessions

    @Test
    fun `a short background keeps the session`() {
        // Switching apps for a moment is not a new session — otherwise every glance at a
        // notification would fold the report the tester is in the middle of producing.
        val start = 1_769_616_000_000
        val tracker = tracker(processStartedAtMillis = start)
        tracker.noteEnteredBackground(start + 60_000)
        tracker.noteEnteredForeground(start + 180_000)

        val stamp = tracker.stampForReport(start + 300_000)
        assertEquals(start, stamp.sessionStartedAtMillis)
        assertEquals(1, stamp.sessionOrdinal)
        assertTrue(stamp.resumes.isEmpty())
    }

    @Test
    fun `a long background opens a new session`() {
        // Past the threshold the three things the panel reads move as one: the new session
        // start, the next ordinal, and the marker that shows where the split happened.
        val start = 1_769_616_000_000
        val tracker = tracker(processStartedAtMillis = start)
        val leftAt = start + 600_000
        val returnedAt = leftAt + CollieSessionTracker.BACKGROUND_SESSION_THRESHOLD_MILLIS + 1_200_000
        tracker.noteEnteredBackground(leftAt)
        tracker.noteEnteredForeground(returnedAt)

        val stamp = tracker.stampForReport(returnedAt + 60_000)
        assertEquals(returnedAt, stamp.sessionStartedAtMillis)
        assertEquals(2, stamp.sessionOrdinal)
        assertEquals(1, stamp.resumes.size)
        assertEquals(returnedAt, stamp.resumes.first().atMillis)
        assertEquals(50, stamp.resumes.first().backgroundMinutes)
        assertEquals("the process did not restart", start, stamp.processStartedAtMillis)
    }

    /** The threshold is half of the contract; the other half is that iOS uses the same one. */
    @Test
    fun `the background threshold matches the iOS SDK`() {
        assertEquals(30L * 60L * 1_000L, CollieSessionTracker.BACKGROUND_SESSION_THRESHOLD_MILLIS)
    }

    // MARK: - Markers

    @Test
    fun `the previous report marker sits on the boundary`() {
        // The panel keeps an entry equal to the boundary on the new side, so this is the line
        // drawn directly under the collapsed block — without it the fold happens but nothing
        // says where.
        val previousReportAtMillis = 1_769_615_000_000
        val markers = CollieSessionTracker.markerEntries(
            CollieSessionTracker.ReportStamp(
                processStartedAtMillis = 1_769_610_000_000,
                sessionStartedAtMillis = 1_769_610_000_000,
                sessionOrdinal = 2,
                previousReportAtMillis = previousReportAtMillis,
                sequence = 2,
                resumes = emptyList(),
            ),
        )
        val marker = markers.single { it.message == "Previous report submitted" }
        assertEquals(previousReportAtMillis, marker.epochMillis)
        assertTrue(markers.all { it.category == "collie" })
    }

    @Test
    fun `markers are omitted when the event did not happen`() {
        val markers = CollieSessionTracker.markerEntries(
            CollieSessionTracker.ReportStamp(
                processStartedAtMillis = 1_769_616_000_000,
                sessionStartedAtMillis = 1_769_616_000_000,
                sessionOrdinal = 1,
                previousReportAtMillis = null,
                sequence = 1,
                resumes = emptyList(),
            ),
        )
        assertEquals(1, markers.size)
        assertTrue(markers.single().message.startsWith("Session started — "))
    }

    @Test
    fun `the resume marker reads in whole minutes`() {
        val markers = CollieSessionTracker.markerEntries(
            CollieSessionTracker.ReportStamp(
                processStartedAtMillis = 1_769_616_000_000,
                sessionStartedAtMillis = 1_769_619_000_000,
                sessionOrdinal = 2,
                previousReportAtMillis = null,
                sequence = 1,
                resumes = listOf(
                    CollieSessionTracker.Resume(
                        atMillis = 1_769_619_000_000,
                        backgroundMillis = 47L * 60L * 1_000L + 30_000L,
                    ),
                ),
            ),
        )
        assertTrue(markers.any { it.message == "Session resumed after 47 min background" })
    }

    // MARK: - Merging (lossless)

    @Test
    fun `merge keeps every host entry in order`() {
        // Not one host entry is dropped, rewritten or reordered — the markers are added around
        // them, in their chronological places.
        val hostEntries = (0 until 5).map { index ->
            CollieLogEntry(
                epochMillis = 1_769_616_000_000 + index * 100_000L,
                level = "info",
                category = "network",
                message = "host-$index",
            )
        }
        val markers = listOf(
            CollieLogEntry(1_769_616_250_000, "info", "collie", "Previous report submitted"),
            CollieLogEntry(1_769_615_000_000, "info", "collie", "Session started — earlier"),
        )

        val merged = CollieSessionTracker.merge(hostEntries, markers)

        assertEquals(hostEntries.size + markers.size, merged.size)
        assertEquals(
            hostEntries.map { it.message },
            merged.filter { it.category != "collie" }.map { it.message },
        )
        assertEquals(
            listOf(
                "Session started — earlier",
                "host-0", "host-1", "host-2",
                "Previous report submitted",
                "host-3", "host-4",
            ),
            merged.map { it.message },
        )
    }

    @Test
    fun `a marker follows host entries with the same timestamp`() {
        // An entry captured at the very instant of the boundary belongs to the new side, so a
        // marker goes *after* the host entries that share its timestamp.
        val instant = 1_769_616_000_000
        val merged = CollieSessionTracker.merge(
            hostEntries = listOf(CollieLogEntry(instant, "info", "network", "host")),
            markers = listOf(CollieLogEntry(instant, "info", "collie", "marker")),
        )
        assertEquals(listOf("host", "marker"), merged.map { it.message })
    }
}
