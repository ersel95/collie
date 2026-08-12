package com.collie.internal

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.collie.CollieLogEntry

/**
 * Session context for a report: which logical session it belongs to, when the previous
 * report was filed from this device, and how many have been filed in total.
 *
 * **Why this exists.** Testers do not kill the app. Collie's log stream lives for as long as
 * the process does, so the tenth report from a device carries the nine earlier reports'
 * navigation and network history along with it, and the part that is actually new drowns in
 * the repetition — in the panel and in the Jira issue alike.
 *
 * Nothing is dropped to fix that. The fields produced here are **presentation metadata**:
 * the panel folds everything older than the boundary into a collapsed block and leaves the
 * newer part open, so an `appConfig` or `login` call fired once at session start is still one
 * click away. `entries` stay lossless — see [com.collie.BugReportService.sendReport].
 *
 * The panel finds the boundary from `previousReportAt`, falling back to `sessionStartedAt`
 * when a device files its first report. Both travel as ISO-8601 with an offset, the same as
 * every other timestamp in the envelope.
 *
 * A **logical session** starts when Collie is configured and starts over when the app returns
 * from a long background — that is what tells "the tester came back after lunch" apart from
 * "the tester switched apps for ten seconds". `sessionOrdinal` and `sequence` outlive the
 * process (they are persisted), so killing the app does not restart the counters;
 * `processStartedAt` is the one field that deliberately does.
 *
 * This is the Android half of a pair: every rule here holds identically in
 * `SessionTracker.swift`, because the panel folds one shape for both platforms.
 */
internal class CollieSessionTracker(
    private val store: Store,
    internal val processStartedAtMillis: Long = System.currentTimeMillis(),
) {

    /**
     * The persistent half of the state. An interface rather than `SharedPreferences`
     * directly so the counters can be tested without an Android framework stub.
     */
    internal interface Store {
        fun readLong(key: String): Long?
        fun writeLong(key: String, value: Long)
    }

    /** A return from a long background — one logical session ending and the next starting. */
    internal data class Resume(val atMillis: Long, val backgroundMillis: Long) {
        /** Whole minutes spent in the background (integer division, like iOS's). */
        val backgroundMinutes: Int get() = (backgroundMillis / 60_000L).toInt()
    }

    /** The session context of a single report, taken at submission time. */
    internal data class ReportStamp(
        val processStartedAtMillis: Long,
        val sessionStartedAtMillis: Long,
        val sessionOrdinal: Int,
        val previousReportAtMillis: Long?,
        val sequence: Int,
        val resumes: List<Resume>,
    )

    private val lock = Any()
    private var sessionStartedAtMillis: Long = processStartedAtMillis
    private var sessionOrdinal: Int
    private val resumes = mutableListOf<Resume>()
    private var backgroundedAtMillis: Long? = null
    private var observing = false

    init {
        // Configuring Collie opens a logical session: `sessionStartedAt` is now and the
        // persistent ordinal moves on by one.
        sessionOrdinal = nextOrdinal()
    }

    // MARK: - Lifecycle

    /**
     * Starts watching the app's background/foreground transitions. Called once, from
     * `BugReportService.bootstrap()`.
     *
     * `ProcessLifecycleOwner` must be touched from the main thread, and `configure` may be
     * called from anywhere, so the registration is posted there.
     */
    internal fun startObservingLifecycle() {
        synchronized(lock) {
            if (observing) return
            observing = true
        }
        Handler(Looper.getMainLooper()).post {
            runCatching {
                ProcessLifecycleOwner.get().lifecycle.addObserver(
                    object : DefaultLifecycleObserver {
                        override fun onStop(owner: LifecycleOwner) {
                            noteEnteredBackground(System.currentTimeMillis())
                        }

                        override fun onStart(owner: LifecycleOwner) {
                            noteEnteredForeground(System.currentTimeMillis())
                        }
                    },
                )
            }
        }
    }

    internal fun noteEnteredBackground(atMillis: Long) {
        synchronized(lock) { backgroundedAtMillis = atMillis }
    }

    /**
     * A return from the background. Past the threshold the three things the panel reads move
     * together: a new `sessionStartedAt`, the next `sessionOrdinal`, and the resume marker
     * that lands in `entries` at exactly that instant.
     */
    internal fun noteEnteredForeground(atMillis: Long) {
        synchronized(lock) {
            val leftAt = backgroundedAtMillis ?: return
            backgroundedAtMillis = null

            val elapsed = atMillis - leftAt
            if (elapsed < BACKGROUND_SESSION_THRESHOLD_MILLIS) return

            sessionStartedAtMillis = atMillis
            sessionOrdinal = nextOrdinal()
            resumes += Resume(atMillis = atMillis, backgroundMillis = elapsed)
            // A device left running for days would otherwise grow this without bound; the
            // markers only describe the current process's log stream anyway.
            while (resumes.size > MAX_RETAINED_RESUMES) resumes.removeAt(0)
        }
    }

    // MARK: - Reports

    /**
     * The session context for a report captured at [capturedAtMillis], advancing the
     * persistent counters: `sequence` moves on and this report's timestamp becomes the next
     * report's `previousReportAt`.
     *
     * Called once per submission, while the envelope is built. A queued report keeps the
     * envelope it was built with and reuses it on every retry, so a retry cannot advance the
     * counters a second time.
     */
    internal fun stampForReport(capturedAtMillis: Long): ReportStamp = synchronized(lock) {
        val previousReportAtMillis = store.readLong(KEY_PREVIOUS_REPORT_AT)
        val sequence = ((store.readLong(KEY_SEQUENCE) ?: 0L) + 1L)
        store.writeLong(KEY_SEQUENCE, sequence)
        store.writeLong(KEY_PREVIOUS_REPORT_AT, capturedAtMillis)

        ReportStamp(
            processStartedAtMillis = processStartedAtMillis,
            sessionStartedAtMillis = sessionStartedAtMillis,
            sessionOrdinal = sessionOrdinal,
            previousReportAtMillis = previousReportAtMillis,
            sequence = sequence.toInt(),
            resumes = resumes.toList(),
        )
    }

    private fun nextOrdinal(): Int {
        val next = (store.readLong(KEY_SESSION_ORDINAL) ?: 0L) + 1L
        store.writeLong(KEY_SESSION_ORDINAL, next)
        return next.toInt()
    }

    internal companion object {

        /**
         * How long the app must stay in the background for the return to count as a new
         * logical session.
         *
         * ⚠️ **Must stay identical to the iOS SDK's
         * `CollieSessionTracker.backgroundSessionThreshold`.** The same tester behaviour has
         * to split into the same sessions on both platforms; a threshold that drifts apart
         * makes two reports of the same scenario fold at different points, and the panel has
         * no way to tell that apart from a real difference.
         */
        internal const val BACKGROUND_SESSION_THRESHOLD_MILLIS: Long = 30L * 60L * 1_000L

        private const val MAX_RETAINED_RESUMES = 100

        private const val PREFERENCES_NAME = "com.collie.bugreporter"
        private const val KEY_SESSION_ORDINAL = "com.collie.session.ordinal"
        private const val KEY_SEQUENCE = "com.collie.report.sequence"
        private const val KEY_PREVIOUS_REPORT_AT = "com.collie.report.previousAt"

        /** The counters live beside the device id, in Collie's own preferences. */
        internal fun preferencesStore(context: Context): Store {
            val preferences = context.applicationContext
                .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            return object : Store {
                override fun readLong(key: String): Long? =
                    if (preferences.contains(key)) preferences.getLong(key, 0L) else null

                override fun writeLong(key: String, value: Long) {
                    preferences.edit().putLong(key, value).apply()
                }
            }
        }

        /**
         * Collie's own synthetic entries for a report — the session boundaries an analyst
         * reads off the timeline. All of them use `category = "collie"`, which is what the
         * panel renders as a rule with a label.
         *
         * `Previous report submitted` carries **exactly** `previousReportAt`, so it lands on
         * the fold boundary itself: the panel keeps an entry equal to the boundary on the new
         * side, which puts this marker directly under the collapsed block, as the line that
         * shows where the previous report ended.
         */
        internal fun markerEntries(stamp: ReportStamp): List<CollieLogEntry> = buildList {
            add(
                CollieLogEntry(
                    epochMillis = stamp.processStartedAtMillis,
                    level = "info",
                    category = "collie",
                    message = "Session started — " +
                        ReportEnvelopeBuilder.dateTimeString(stamp.processStartedAtMillis),
                ),
            )
            stamp.previousReportAtMillis?.let { previousReportAtMillis ->
                add(
                    CollieLogEntry(
                        epochMillis = previousReportAtMillis,
                        level = "info",
                        category = "collie",
                        message = "Previous report submitted",
                    ),
                )
            }
            stamp.resumes.forEach { resume ->
                add(
                    CollieLogEntry(
                        epochMillis = resume.atMillis,
                        level = "info",
                        category = "collie",
                        message = "Session resumed after ${resume.backgroundMinutes} min background",
                    ),
                )
            }
        }

        /**
         * Merges Collie's markers into the host's log stream **at their chronological
         * positions**, without reordering, dropping or rewriting a single host entry: each
         * marker goes after every entry at or before its own timestamp.
         */
        internal fun merge(
            hostEntries: List<CollieLogEntry>,
            markers: List<CollieLogEntry>,
        ): List<CollieLogEntry> {
            val entries = hostEntries.toMutableList()
            markers.sortedBy { it.epochMillis }.forEach { marker ->
                val index = entries
                    .indexOfFirst { it.epochMillis > marker.epochMillis }
                    .takeIf { it >= 0 }
                    ?: entries.size
                entries.add(index, marker)
            }
            return entries
        }
    }
}
