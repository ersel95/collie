#if canImport(UIKit)
import UIKit

/// Bridge that gathers the 2 fields from the report sheet + the screenshots it holds +
/// device/app meta and hands them to `Collie`'s `BugReportService`.
///
/// The log snapshot (the host's `logSnapshotProvider`) is collected on the service side;
/// this only prepares the data coming from the UI (screenshot + fields + name).
@MainActor
enum BugReportComposer {

    /// Sends the report.
    ///
    /// - Parameter shots: In the order the form holds them; the transport keeps that order,
    ///   so it is the order the analyst sees. Each one carries its own capture event, which
    ///   is why they travel as pairs rather than as two lists: an image that fails to encode
    ///   must take its marker with it, or the stream announces "screenshot 3 captured"
    ///   beside two pictures and sends the analyst looking for one that never arrived.
    static func send(
        whatHappened: String,
        testerName: String?,
        shots: [BugReportShot]
    ) async -> CollieSubmitOutcome {
        guard let service = Collie.bugReportService else {
            return .rejected("Collie is not configured")
        }

        let quality = service.screenshotJPEGQuality
        // Per image, not for all of them together: each one is uploaded on its own, so
        // attaching a fifth must not shrink the first four.
        let maxBytes = service.maxScreenshotBytes
        // The form already stops at the limit; capping again here means a caller that does
        // not (a host driving the service directly) cannot exceed what the panel displays.
        var jpegs: [Data] = []
        var events: [CollieScreenshotEvent] = []
        for shot in shots.prefix(service.maxScreenshots) {
            guard let data = encodeJPEG(shot.image, quality: quality, maxBytes: maxBytes) else {
                continue
            }
            jpegs.append(data)
            events.append(shot.event)
        }

        let identity = CollieDeviceIdentity.current()
        // Capture the point-in-time device state (battery/network/thermal/disk/memory…)
        // at the moment the report is taken.
        let telemetry = CollieTelemetryCollector.capture()

        return await service.sendReport(
            whatHappened: whatHappened,
            testerName: testerName,
            screenshotsJPEG: jpegs,
            screenshotEvents: events,
            identity: identity,
            telemetry: telemetry
        )
    }

    /// Compresses ONE image to JPEG; when `maxBytes` is exceeded, gradually lowers
    /// quality/size.
    static func encodeJPEG(_ image: UIImage, quality: Double, maxBytes: Int) -> Data? {
        var currentQuality = CGFloat(quality)
        var data = image.jpegData(compressionQuality: currentQuality)

        // First try lowering the quality.
        while let d = data, maxBytes > 0, d.count > maxBytes, currentQuality > 0.2 {
            currentQuality -= 0.15
            data = image.jpegData(compressionQuality: currentQuality)
        }

        // Still too large: scale the image down.
        var scaledImage = image
        while let d = data, maxBytes > 0, d.count > maxBytes,
              scaledImage.size.width > 320, scaledImage.size.height > 320 {
            let newSize = CGSize(width: scaledImage.size.width * 0.7, height: scaledImage.size.height * 0.7)
            scaledImage = resize(scaledImage, to: newSize)
            data = scaledImage.jpegData(compressionQuality: currentQuality)
        }
        return data
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
