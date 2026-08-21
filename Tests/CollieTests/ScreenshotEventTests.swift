import XCTest
@testable import Collie

/// The markers that put a report's pictures on the log timeline.
///
/// A report can carry five images taken minutes apart, and without these the analyst sees a
/// row of screenshots with no idea which screen came first — while the stream beside them is
/// timestamped to the second.
final class ScreenshotEventTests: XCTestCase {

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    func testEachImageGetsAMarkerNumberedByItsPositionInTheReport() {
        let markers = CollieScreenshotEvent.markerEntries(for: [
            CollieScreenshotEvent(date: date(0), source: .captured),
            CollieScreenshotEvent(date: date(30), source: .captured)
        ])

        XCTAssertEqual(markers.map(\.message), [
            "Screenshot 1 captured",
            "Screenshot 2 captured"
        ])
        XCTAssertEqual(markers.map(\.category), ["collie", "collie"])
        XCTAssertEqual(markers.map(\.date), [date(0), date(30)])
        XCTAssertEqual(markers.first?.metadata["screenshot"], "1")
    }

    /// A library image was taken at some earlier, unknown time — saying it was "captured"
    /// then would point the analyst at a moment in the stream that has nothing to do with it.
    func testALibraryImageSaysItWasAttached() {
        let markers = CollieScreenshotEvent.markerEntries(for: [
            CollieScreenshotEvent(date: date(0), source: .library)
        ])

        XCTAssertEqual(markers.first?.message, "Screenshot 1 attached from the photo library")
        XCTAssertEqual(markers.first?.metadata["source"], "library")
    }

    /// The number is the image's position in the report **as sent**. A tester who deletes
    /// the second of three pictures leaves two, and a marker still saying "screenshot 2"
    /// for the one that is now second-to-none would name the wrong picture.
    func testNumberingFollowsTheImagesActuallySent() {
        // The middle image was removed in the form, so its event never gets here.
        let markers = CollieScreenshotEvent.markerEntries(for: [
            CollieScreenshotEvent(date: date(0), source: .captured),
            CollieScreenshotEvent(date: date(120), source: .captured)
        ])

        XCTAssertEqual(markers.map(\.message), [
            "Screenshot 1 captured",
            "Screenshot 2 captured"
        ])
    }

    func testNoImagesMeansNoMarkers() {
        XCTAssertTrue(CollieScreenshotEvent.markerEntries(for: []).isEmpty)
    }

    /// The markers have to land where they happened, not at the end of the stream: the whole
    /// point is reading "screenshot 2 was taken right after this request failed".
    func testMarkersMergeIntoTheStreamAtTheirOwnTimestamps() {
        let host = [
            CollieLogEntry(date: date(10), level: "info", category: "app", message: "first"),
            CollieLogEntry(date: date(100), level: "info", category: "app", message: "second")
        ]
        let markers = CollieScreenshotEvent.markerEntries(for: [
            CollieScreenshotEvent(date: date(50), source: .captured)
        ])

        let merged = CollieSessionTracker.merge(hostEntries: host, markers: markers)

        XCTAssertEqual(merged.map(\.message), ["first", "Screenshot 1 captured", "second"])
    }
}
