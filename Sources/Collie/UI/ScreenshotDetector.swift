#if canImport(UIKit)
import UIKit

public extension Notification.Name {
    /// Posted when the user takes a screenshot — the rendered image is the `object`
    /// (a UIImage).
    static let collieScreenshotCaptured = Notification.Name("com.collie.screenshotCaptured")
}

/// Screenshot detection. The system does NOT hand the screenshot image to the app, so
/// when the notification fires we render the key window ourselves via
/// `UIGraphicsImageRenderer` + `drawHierarchy`.
///
/// Rendering uses `afterScreenUpdates: true` → the system mask of secure (hidden) text
/// fields takes effect and sensitive content does NOT leak into the image (it comes out
/// blank/black). The image still contains every other piece of information visible on
/// screen; informed consent is shown in the sheet.
@MainActor
final class ScreenshotDetector {

    static let shared = ScreenshotDetector()

    private var observer: NSObjectProtocol?
    private init() {}

    var isInstalled: Bool { observer != nil }

    /// Installs the `userDidTakeScreenshotNotification` observer. Idempotent.
    func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ScreenshotDetector.shared.handleScreenshot()
            }
        }
    }

    /// Removes the observer.
    func uninstall() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func handleScreenshot() {
        Collie.diag("Screenshot taken")

        let image = Self.renderKeyWindow()
        NotificationCenter.default.post(name: .collieScreenshotCaptured, object: image)
    }

    /// Renders the key window into an image (excluding Collie's own alert-level windows).
    static func renderKeyWindow() -> UIImage? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
            // Exclude Collie's own top-layer windows (banner/toast).
            .filter { $0.windowLevel < UIWindow.Level.alert }

        guard let window = windows.first(where: \.isKeyWindow)
            ?? windows.max(by: { $0.windowLevel < $1.windowLevel }) else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        return renderer.image { _ in
            // afterScreenUpdates:true is required for the secure-text-field mask (and the
            // final layout) to be reflected in the render; otherwise hidden fields could
            // leak into the image.
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
#endif
