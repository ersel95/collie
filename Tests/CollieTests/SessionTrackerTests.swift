import XCTest
@testable import Collie

/// The session context that lets the panel fold a report's repeated history: persistent
/// counters, logical session boundaries, and the markers that show where those boundaries
/// fall in the log stream.
final class SessionTrackerTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.collie.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeTracker(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CollieSessionTracker {
        CollieSessionTracker(defaults: defaults, now: now)
    }

    // MARK: - Counters

    /// A device's second report points at its first one, to the second.
    func testPreviousReportAtIsTheEarlierReportsCapturedAt() {
        let tracker = makeTracker()
        let first = Date(timeIntervalSince1970: 1_700_000_100)
        let second = Date(timeIntervalSince1970: 1_700_001_000)

        let firstStamp = tracker.stampForReport(capturedAt: first)
        let secondStamp = tracker.stampForReport(capturedAt: second)

        XCTAssertNil(firstStamp.previousReportAt, "the first report has no predecessor")
        XCTAssertEqual(secondStamp.previousReportAt, first)
    }

    func testSequenceStartsAtOneAndCounts() {
        let tracker = makeTracker()
        let stamps = (0..<3).map {
            tracker.stampForReport(capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))
        }
        XCTAssertEqual(stamps.map(\.sequence), [1, 2, 3])
    }

    /// Killing the app must not make a tester's eleventh report look like their first: the
    /// counters live in `UserDefaults`, `processStartedAt` is the one thing that resets.
    func testCountersSurviveAProcessRestart() {
        let firstProcess = makeTracker(now: Date(timeIntervalSince1970: 1_700_000_000))
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let before = firstProcess.stampForReport(capturedAt: capturedAt)

        let relaunchedAt = Date(timeIntervalSince1970: 1_700_090_000)
        let secondProcess = makeTracker(now: relaunchedAt)
        let after = secondProcess.stampForReport(capturedAt: Date(timeIntervalSince1970: 1_700_090_100))

        XCTAssertEqual(after.sequence, before.sequence + 1)
        XCTAssertEqual(after.sessionOrdinal, before.sessionOrdinal + 1)
        XCTAssertEqual(after.previousReportAt, capturedAt)
        XCTAssertEqual(after.processStartedAt, relaunchedAt)
        XCTAssertEqual(after.sessionStartedAt, relaunchedAt)
    }

    // MARK: - Logical sessions

    /// Switching apps for a moment is not a new session — otherwise every glance at a
    /// notification would fold the report the tester is in the middle of producing.
    func testAShortBackgroundKeepsTheSession() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = makeTracker(now: start)
        tracker.noteEnteredBackground(at: start.addingTimeInterval(60))
        tracker.noteEnteredForeground(at: start.addingTimeInterval(180))

        let stamp = tracker.stampForReport(capturedAt: start.addingTimeInterval(300))
        XCTAssertEqual(stamp.sessionStartedAt, start)
        XCTAssertEqual(stamp.sessionOrdinal, 1)
        XCTAssertTrue(stamp.resumes.isEmpty)
    }

    /// Past the threshold the three things the panel reads move as one: the new session
    /// start, the next ordinal, and the marker that shows where the split happened.
    func testALongBackgroundOpensANewSession() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let tracker = makeTracker(now: start)
        let leftAt = start.addingTimeInterval(600)
        let returnedAt = leftAt.addingTimeInterval(CollieSessionTracker.backgroundSessionThreshold + 1_200)
        tracker.noteEnteredBackground(at: leftAt)
        tracker.noteEnteredForeground(at: returnedAt)

        let stamp = tracker.stampForReport(capturedAt: returnedAt.addingTimeInterval(60))
        XCTAssertEqual(stamp.sessionStartedAt, returnedAt)
        XCTAssertEqual(stamp.sessionOrdinal, 2)
        XCTAssertEqual(stamp.resumes.count, 1)
        XCTAssertEqual(stamp.resumes.first?.date, returnedAt)
        XCTAssertEqual(stamp.resumes.first?.backgroundMinutes, 50)
        XCTAssertEqual(stamp.processStartedAt, start, "the process did not restart")
    }

    // MARK: - Markers

    /// The marker sits **exactly** on the boundary. The panel keeps an entry equal to the
    /// boundary on the new side, so this is the line drawn directly under the collapsed
    /// block — without it the fold happens but nothing says where.
    func testPreviousReportMarkerSitsOnTheBoundary() throws {
        let previousReportAt = Date(timeIntervalSince1970: 1_699_999_000)
        let stamp = CollieSessionTracker.ReportStamp(
            processStartedAt: Date(timeIntervalSince1970: 1_699_990_000),
            sessionStartedAt: Date(timeIntervalSince1970: 1_699_990_000),
            sessionOrdinal: 2,
            previousReportAt: previousReportAt,
            sequence: 2,
            resumes: []
        )
        let markers = CollieSessionTracker.markerEntries(for: stamp)
        let marker = try XCTUnwrap(markers.first { $0.message == "Previous report submitted" })
        XCTAssertEqual(marker.date, previousReportAt)
        XCTAssertTrue(markers.allSatisfy { $0.category == "collie" })
    }

    func testMarkersAreOmittedWhenTheEventDidNotHappen() {
        let stamp = CollieSessionTracker.ReportStamp(
            processStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionOrdinal: 1,
            previousReportAt: nil,
            sequence: 1,
            resumes: []
        )
        let markers = CollieSessionTracker.markerEntries(for: stamp)
        XCTAssertEqual(markers.map(\.message.isEmpty), [false])
        XCTAssertEqual(markers.count, 1, "only the session-start marker")
        XCTAssertTrue(markers[0].message.hasPrefix("Session started — "))
    }

    // MARK: - Merging (lossless)

    /// Not one host entry is dropped, rewritten or reordered — the markers are added
    /// around them, in their chronological places.
    func testMergeKeepsEveryHostEntryInOrder() {
        let hostEntries = (0..<5).map { index in
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 100)),
                level: "info",
                category: "network",
                message: "host-\(index)"
            )
        }
        let markers = [
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_250),
                level: "info", category: "collie", message: "Previous report submitted"
            ),
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_699_999_000),
                level: "info", category: "collie", message: "Session started — earlier"
            ),
        ]

        let merged = CollieSessionTracker.merge(hostEntries: hostEntries, markers: markers)

        XCTAssertEqual(merged.count, hostEntries.count + markers.count)
        XCTAssertEqual(
            merged.filter { $0.category != "collie" }.map(\.message),
            hostEntries.map(\.message)
        )
        XCTAssertEqual(
            merged.map(\.message),
            [
                "Session started — earlier",
                "host-0", "host-1", "host-2",
                "Previous report submitted",
                "host-3", "host-4",
            ]
        )
    }

    /// An entry captured at the very instant of the boundary belongs to the new side, so a
    /// marker goes *after* the host entries that share its timestamp.
    func testAMarkerFollowsHostEntriesWithTheSameTimestamp() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let hostEntries = [
            CollieLogEntry(date: instant, level: "info", category: "network", message: "host")
        ]
        let markers = [
            CollieLogEntry(date: instant, level: "info", category: "collie", message: "marker")
        ]
        let merged = CollieSessionTracker.merge(hostEntries: hostEntries, markers: markers)
        XCTAssertEqual(merged.map(\.message), ["host", "marker"])
    }
}
