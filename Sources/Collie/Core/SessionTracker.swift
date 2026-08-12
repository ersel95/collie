import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Session context for a report: which logical session it belongs to, when the previous
/// report was filed from this device, and how many have been filed in total.
///
/// **Why this exists.** Testers do not kill the app. Collie's log stream lives for as long
/// as the process does, so the tenth report from a device carries the nine earlier reports'
/// navigation and network history along with it, and the part that is actually new drowns
/// in the repetition — in the panel and in the Jira issue alike.
///
/// Nothing is dropped to fix that. The fields produced here are **presentation metadata**:
/// the panel folds everything older than the boundary into a collapsed block and leaves the
/// newer part open, so an `appConfig` or `login` call fired once at session start is still
/// one click away. `entries` stay lossless — see `BugReportService.sendReport`.
///
/// The panel finds the boundary from `previousReportAt`, falling back to `sessionStartedAt`
/// when a device files its first report. Both travel as ISO-8601 with an offset, the same
/// as every other timestamp in the envelope.
///
/// A **logical session** starts when Collie is configured and starts over when the app
/// returns from a long background — that is what tells "the tester came back after lunch"
/// apart from "the tester switched apps for ten seconds". `sessionOrdinal` and `sequence`
/// outlive the process (`UserDefaults`), so killing the app does not restart the counters;
/// `processStartedAt` is the one field that deliberately does.
final class CollieSessionTracker: @unchecked Sendable {

    /// How long the app must stay in the background for the return to count as a new
    /// logical session.
    ///
    /// ⚠️ **Must stay identical to the Android SDK's
    /// `CollieSessionTracker.BACKGROUND_SESSION_THRESHOLD_MILLIS`.** The same tester
    /// behaviour has to split into the same sessions on both platforms; a threshold that
    /// drifts apart makes two reports of the same scenario fold at different points, and
    /// the panel has no way to tell that apart from a real difference.
    static let backgroundSessionThreshold: TimeInterval = 30 * 60

    /// A return from a long background — one logical session ending and the next starting.
    struct Resume: Sendable {
        let date: Date
        let backgroundSeconds: TimeInterval

        /// Whole minutes spent in the background (integer division, like Android's).
        var backgroundMinutes: Int { Int(backgroundSeconds) / 60 }
    }

    /// The session context of a single report, taken at submission time.
    struct ReportStamp: Sendable {
        let processStartedAt: Date
        let sessionStartedAt: Date
        let sessionOrdinal: Int
        let previousReportAt: Date?
        let sequence: Int
        let resumes: [Resume]
    }

    /// When `Collie.configure(...)` ran — the process's own start, reset by a relaunch.
    let processStartedAt: Date

    private let defaults: UserDefaults
    private let lock = NSLock()

    private var sessionStartedAt: Date
    private var sessionOrdinal: Int
    private var resumes: [Resume] = []
    private var backgroundedAt: Date?
    private var observers: [NSObjectProtocol] = []

    /// Configuring Collie opens a logical session: `sessionStartedAt` is now and the
    /// persistent ordinal moves on by one.
    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        self.processStartedAt = now
        self.sessionStartedAt = now
        let ordinal = defaults.integer(forKey: Keys.sessionOrdinal) + 1
        defaults.set(ordinal, forKey: Keys.sessionOrdinal)
        self.sessionOrdinal = ordinal
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Lifecycle

    /// Starts watching the app's background/foreground transitions. Called once, from
    /// `BugReportService.bootstrap()`.
    func startObservingLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.noteEnteredBackground(at: Date())
            }
        )
        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.noteEnteredForeground(at: Date())
            }
        )
        #endif
    }

    func noteEnteredBackground(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        backgroundedAt = date
    }

    /// A return from the background. Past the threshold the three things the panel reads
    /// move together: a new `sessionStartedAt`, the next `sessionOrdinal`, and the resume
    /// marker that lands in `entries` at exactly that instant.
    func noteEnteredForeground(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil

        let elapsed = date.timeIntervalSince(backgroundedAt)
        guard elapsed >= Self.backgroundSessionThreshold else { return }

        sessionStartedAt = date
        sessionOrdinal = defaults.integer(forKey: Keys.sessionOrdinal) + 1
        defaults.set(sessionOrdinal, forKey: Keys.sessionOrdinal)
        resumes.append(Resume(date: date, backgroundSeconds: elapsed))
        // A device left running for days would otherwise grow this without bound; the
        // markers only describe the current process's log stream anyway.
        if resumes.count > Self.maxRetainedResumes {
            resumes.removeFirst(resumes.count - Self.maxRetainedResumes)
        }
    }

    // MARK: - Reports

    /// The session context for a report captured at `capturedAt`, advancing the persistent
    /// counters: `sequence` moves on and `capturedAt` becomes the next report's
    /// `previousReportAt`.
    ///
    /// Called once per submission, while the envelope is built. A queued report keeps the
    /// envelope it was built with and reuses it on every retry, so a retry cannot advance
    /// the counters a second time.
    func stampForReport(capturedAt: Date) -> ReportStamp {
        lock.lock(); defer { lock.unlock() }

        let previousReportAt = defaults.object(forKey: Keys.previousReportAt) as? Double
        let sequence = defaults.integer(forKey: Keys.sequence) + 1
        defaults.set(sequence, forKey: Keys.sequence)
        defaults.set(capturedAt.timeIntervalSince1970, forKey: Keys.previousReportAt)

        return ReportStamp(
            processStartedAt: processStartedAt,
            sessionStartedAt: sessionStartedAt,
            sessionOrdinal: sessionOrdinal,
            previousReportAt: previousReportAt.map(Date.init(timeIntervalSince1970:)),
            sequence: sequence,
            resumes: resumes
        )
    }

    // MARK: - Markers

    /// Collie's own synthetic entries for a report — the session boundaries an analyst
    /// reads off the timeline. All of them use `category: "collie"`, which is what the
    /// panel renders as a rule with a label.
    ///
    /// `Previous report submitted` carries **exactly** `previousReportAt`, so it lands on
    /// the fold boundary itself: the panel keeps an entry equal to the boundary on the new
    /// side, which puts this marker directly under the collapsed block, as the line that
    /// shows where the previous report ended.
    static func markerEntries(for stamp: ReportStamp) -> [CollieLogEntry] {
        var markers: [CollieLogEntry] = [
            CollieLogEntry(
                date: stamp.processStartedAt,
                level: "info",
                category: "collie",
                message: "Session started — \(ReportEnvelopeBuilder.dateTimeString(stamp.processStartedAt))"
            )
        ]

        if let previousReportAt = stamp.previousReportAt {
            markers.append(
                CollieLogEntry(
                    date: previousReportAt,
                    level: "info",
                    category: "collie",
                    message: "Previous report submitted"
                )
            )
        }

        markers.append(
            contentsOf: stamp.resumes.map { resume in
                CollieLogEntry(
                    date: resume.date,
                    level: "info",
                    category: "collie",
                    message: "Session resumed after \(resume.backgroundMinutes) min background"
                )
            }
        )

        return markers
    }

    /// Merges Collie's markers into the host's log stream **at their chronological
    /// positions**, without reordering, dropping or rewriting a single host entry: each
    /// marker goes after every entry at or before its own timestamp.
    static func merge(
        hostEntries: [CollieLogEntry],
        markers: [CollieLogEntry]
    ) -> [CollieLogEntry] {
        var entries = hostEntries
        for marker in markers.sorted(by: { $0.date < $1.date }) {
            let index = entries.firstIndex { $0.date > marker.date } ?? entries.endIndex
            entries.insert(marker, at: index)
        }
        return entries
    }

    // MARK: - Storage

    private static let maxRetainedResumes = 100

    private enum Keys {
        static let sessionOrdinal = "com.collie.session.ordinal"
        static let sequence = "com.collie.report.sequence"
        static let previousReportAt = "com.collie.report.previousAt"
    }

    /// Clears the persistent counters. Tests only.
    static func resetPersistentState(in defaults: UserDefaults = .standard) {
        [Keys.sessionOrdinal, Keys.sequence, Keys.previousReportAt].forEach(defaults.removeObject(forKey:))
    }
}
