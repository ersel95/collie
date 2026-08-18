import XCTest
@testable import CollieFirebase

/// The report that triggered this: an envelope of 1.003.443 bytes was rejected outright,
/// so the tester's words, the screenshot and the whole stream were lost — even though the
/// part that would have been written to the report document was a few kilobytes.
final class FirestoreTransportTrimTests: XCTestCase {

    // MARK: - Fixtures

    /// One log entry, shaped the way `ReportEnvelopeBuilder` encodes it, padded to roughly
    /// `bytes` so a budget can be expressed in whole entries.
    private func entry(_ index: Int, bytes: Int = 1_000) -> [String: Any] {
        [
            "date": "2026-08-18T12:00:\(String(format: "%02d", index % 60))Z",
            "level": "info",
            "category": "network",
            "message": "entry \(index)",
            "metadata": ["responseBody": String(repeating: "x", count: bytes)],
        ]
    }

    private func message(_ value: Any) -> String {
        ((value as? [String: Any])?["message"] as? String) ?? ""
    }

    // MARK: - A stream that fits is untouched

    func testStreamWithinBudgetIsReturnedUnchanged() throws {
        let entries = (0..<5).map { entry($0) }

        let result = FirestoreTransport.trimEntries(entries, budget: 900_000)

        XCTAssertEqual(result.dropped, 0)
        let kept = try XCTUnwrap(result.value as? [Any])
        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(message(kept[0]), "entry 0")
    }

    // MARK: - An oversized stream loses its OLDEST end

    func testTrimKeepsTheNewestEntriesAndDropsTheOldest() throws {
        let entries = (0..<100).map { entry($0) }   // ~100 KB

        let result = FirestoreTransport.trimEntries(entries, budget: 20_000)

        XCTAssertGreaterThan(result.dropped, 0)
        let kept = try XCTUnwrap(result.value as? [Any])
        // The marker heads the stream; everything after it is the tail of the original.
        XCTAssertEqual(kept.count, 100 - result.dropped + 1)
        XCTAssertEqual(message(kept[1]), "entry \(result.dropped)")
        XCTAssertEqual(message(kept[kept.count - 1]), "entry 99")
    }

    func testTrimmedStreamFitsTheBudget() throws {
        let entries = (0..<100).map { entry($0) }
        let budget = 20_000

        let result = FirestoreTransport.trimEntries(entries, budget: budget)

        let size = try XCTUnwrap(FirestoreTransport.byteSize(of: result.value))
        XCTAssertLessThanOrEqual(size, budget)
    }

    // MARK: - The trim is never silent

    func testMarkerEntryRecordsWhatWasDropped() throws {
        let entries = (0..<100).map { entry($0) }

        let result = FirestoreTransport.trimEntries(entries, budget: 20_000)

        let kept = try XCTUnwrap(result.value as? [Any])
        let marker = try XCTUnwrap(kept.first as? [String: Any])
        XCTAssertEqual(marker["category"] as? String, "collie")
        XCTAssertEqual(marker["level"] as? String, "warning")
        XCTAssertTrue(message(marker).contains("\(result.dropped)"))
        let metadata = try XCTUnwrap(marker["metadata"] as? [String: String])
        XCTAssertEqual(metadata["droppedEntries"], String(result.dropped))
    }

    /// The panel places its session fold by comparing timestamps, so a marker stamped
    /// "now" would jump the timeline. It carries the timestamp of the cut instead.
    func testMarkerCarriesTheTimestampOfTheCut() throws {
        let entries = (0..<100).map { entry($0) }

        let result = FirestoreTransport.trimEntries(entries, budget: 20_000)

        let kept = try XCTUnwrap(result.value as? [Any])
        let marker = try XCTUnwrap(kept.first as? [String: Any])
        let firstKept = try XCTUnwrap(kept[1] as? [String: Any])
        XCTAssertEqual(marker["date"] as? String, firstKept["date"] as? String)
    }

    // MARK: - Degenerate budgets

    /// A budget smaller than a single entry still yields a writable document rather than
    /// a failure: the marker alone tells the analyst the stream did not fit.
    func testBudgetTooSmallForAnyEntryKeepsOnlyTheMarker() throws {
        let entries = (0..<10).map { entry($0) }

        let result = FirestoreTransport.trimEntries(entries, budget: 100)

        XCTAssertEqual(result.dropped, 10)
        let kept = try XCTUnwrap(result.value as? [Any])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual((kept[0] as? [String: Any])?["category"] as? String, "collie")
    }

    func testEmptyStreamIsLeftAlone() throws {
        let result = FirestoreTransport.trimEntries([Any](), budget: 10)

        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(try XCTUnwrap(result.value as? [Any]).count, 0)
    }

    /// Anything that is not an array is passed through: the transport writes whatever the
    /// envelope carried rather than inventing a shape.
    func testNonArrayStreamIsPassedThrough() {
        let result = FirestoreTransport.trimEntries("not a stream", budget: 1)

        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(result.value as? String, "not a stream")
    }

    // MARK: - Size measurement

    /// The regression itself: the report document is what the limit protects, and it is
    /// a fraction of the envelope once the stream is lifted out.
    func testReportDocumentIsMeasuredWithoutTheStream() throws {
        var document: [String: Any] = [
            "app": ["bundleId": "com.example.app", "version": "1.0"],
            "report": ["whatHappened": "Bununda rengi background success olmalı: 70c68e"],
            "entries": (0..<1_000).map { entry($0) },   // ~1 MB, like the failing report
        ]
        let whole = try XCTUnwrap(FirestoreTransport.byteSize(of: document))
        XCTAssertGreaterThan(whole, 900_000)

        document.removeValue(forKey: "entries")

        let withoutStream = try XCTUnwrap(FirestoreTransport.byteSize(of: document))
        XCTAssertLessThan(withoutStream, 900_000)
    }
}
