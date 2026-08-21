import Foundation

/// When one of a report's screenshots arrived, and where it came from.
///
/// A report can carry several images taken minutes apart: the tester shakes, then walks
/// back through the app taking one more on each screen that matters. Without this, the
/// analyst sees a row of pictures with no idea which screen came first or when, while the
/// log stream beside them is timestamped to the second.
///
/// So every image leaves a `collie` marker in the stream at the moment it was taken —
/// `CollieScreenshotEvent.markerEntries(for:)` builds them, and `BugReportService` merges
/// them in at their chronological positions like every other Collie marker. Reading the
/// report becomes "screenshot 2 was taken right here, after this request failed".
public struct CollieScreenshotEvent: Sendable, Equatable {

    /// How the image got into the report. The distinction is worth keeping: a capture is
    /// evidence of what the app was doing at that instant, while a library image was taken
    /// at some earlier, unknown time and only *attached* now.
    public enum Source: String, Sendable {
        /// Rendered from the running app — at shake time, or in screenshot mode.
        case captured
        /// Picked from the photo library.
        case library
    }

    /// When the image was captured (or, for a library image, attached).
    public let date: Date
    public let source: Source

    public init(date: Date, source: Source) {
        self.date = date
        self.source = source
    }

    /// One `collie` log entry per image, numbered the way the panel numbers them.
    ///
    /// The number is the image's **position in the report as sent**, not the order it was
    /// taken in: the tester can delete the second of three pictures, and a marker still
    /// pointing at "screenshot 2" would then name the wrong one. Deleted images produce no
    /// marker at all, because their event never reaches this function.
    public static func markerEntries(for events: [CollieScreenshotEvent]) -> [CollieLogEntry] {
        events.enumerated().map { index, event in
            let number = index + 1
            return CollieLogEntry(
                date: event.date,
                level: "info",
                category: "collie",
                message: event.source == .captured
                    ? "Screenshot \(number) captured"
                    : "Screenshot \(number) attached from the photo library",
                metadata: ["screenshot": String(number), "source": event.source.rawValue]
            )
        }
    }
}
