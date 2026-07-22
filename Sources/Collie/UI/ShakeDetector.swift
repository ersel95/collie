#if canImport(UIKit)
import UIKit
import ObjectiveC

public extension Notification.Name {
    /// Posted when the device is shaken. `BugReportBanner` listens for this.
    static let collieShake = Notification.Name("com.collie.shake")
}

/// Shake detection: implemented via **runtime swizzling** of `UIWindow.motionEnded`.
/// (A plain extension-override could be dead-stripped in an SPM static library and never
/// register with the ObjC runtime; the swizzle stays referenced because it's called from
/// `install()`.)
///
/// Composes with other swizzlers of the same selector: each swizzle calls the previous
/// implementation, so all observers keep firing.
enum ShakeDetector {

    private typealias MotionEndedIMP = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void

    private nonisolated(unsafe) static var installed = false

    /// Swizzles `UIWindow.motionEnded` once; posts `.collieShake` on shake, then calls
    /// the original. Idempotent.
    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true

        let selector = #selector(UIResponder.motionEnded(_:with:))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: MotionEndedIMP.self)
        let typeEncoding = method_getTypeEncoding(method)

        let block: @convention(block) (AnyObject, UIEvent.EventSubtype, UIEvent?) -> Void = { receiver, motion, event in
            if motion == .motionShake {
                NotificationCenter.default.post(name: .collieShake, object: nil)
            }
            original(receiver, selector, motion, event)
        }
        class_replaceMethod(UIWindow.self, selector, imp_implementationWithBlock(block), typeEncoding)
    }
}

/// Renders the current screen into an image. The system never hands us a screenshot;
/// at shake time we render the key window ourselves via `UIGraphicsImageRenderer` +
/// `drawHierarchy`.
///
/// Rendering uses `afterScreenUpdates: true` → the system mask of secure (hidden) text
/// fields takes effect and sensitive content does NOT leak into the image (it comes out
/// blank/black). The image still contains every other piece of information visible on
/// screen; informed consent is shown in the sheet.
@MainActor
enum ScreenRenderer {

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
