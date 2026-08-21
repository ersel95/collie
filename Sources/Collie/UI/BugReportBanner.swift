#if canImport(UIKit)
import UIKit
import SwiftUI

/// The bug-reporter UI orchestrator: when the device is shaken, shows Collie UI inside
/// a **separate `UIWindow`** (never touching the app's hierarchy). By default a shake
/// raises a yes/no bubble from the bottom (**Yes** → the report sheet); with
/// `CollieConfiguration.asksBeforeReporting = false` the question is skipped and the
/// report sheet opens directly. Finally shows a "PROJ-123 created" / "Queued" toast.
@MainActor
final class BugReportBanner {

    static let shared = BugReportBanner()

    private var window: UIWindow?
    private var shakeObserver: NSObjectProtocol?
    private var autoDismissTask: Task<Void, Never>?
    /// What the tester has entered. Owned here rather than by the form, because the form
    /// steps aside for screenshot mode and comes back — see `enterScreenshotMode`.
    private var draft = BugReportDraft()
    /// The screenshot-mode controls, while that mode is up.
    private var screenshotOverlay: ScreenshotModeOverlay?

    /// Handler for taps on the Collie logo in the report sheet's navigation bar
    /// (set via `Collie.onLogoTap`). When set, the logo becomes a switch-tool button.
    var logoTapHandler: (() -> Void)?

    /// The banner auto-dismisses after a few seconds without interaction.
    private let autoDismissAfter: TimeInterval = 6

    private init() {}

    // MARK: - Setup (triggered by Collie.configure)

    /// Installs the shake detector + observer. Called **only when the bug-reporter
    /// opt-in is on**. Idempotent.
    func install() {
        guard shakeObserver == nil else { return }
        // Start telemetry regardless — a hand-off via `Collie.presentReport()` needs it
        // just as much as a shake does.
        CollieTelemetryCollector.prepare()
        // The host can hand the gesture to another tool; Collie is then reached only
        // through `presentReport()`.
        guard Collie.bugReportService?.configuration.activatesOnShake != false else {
            Collie.diag("Shake activation disabled — Collie opens only via presentReport().")
            return
        }
        ShakeDetector.install()
        shakeObserver = NotificationCenter.default.addObserver(
            forName: .collieShake,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BugReportBanner.shared.handleShake()
            }
        }
    }

    // MARK: - Flow

    private func handleShake() {
        Collie.diag("Shake detected")
        // Explicit host choice (`CollieConfiguration.asksBeforeReporting`): ask first —
        // a shake may be accidental — or open the report sheet straight away. Whether
        // tool switching is wired (`Collie.onLogoTap`) does NOT affect this.
        present(askFirst: Collie.bugReportService?.configuration.asksBeforeReporting != false)
    }

    /// Starts the report flow.
    ///
    /// - Parameter askFirst: Show the "Spotted a problem?" question before the form.
    ///   A shake honours `asksBeforeReporting`, because a shake can be accidental. A
    ///   deliberate entry — the host handing off from another diagnostics tool — passes
    ///   `false`: the tester already chose to report, so asking again is a dead click.
    func present(askFirst: Bool) {
        // Gate: don't show anything when the service is absent (opt-in off) or capture
        // is disabled.
        guard Collie.bugReportService?.isCaptureEnabled == true else { return }
        // Don't repeat while a banner/sheet is already visible.
        guard window == nil else { return }
        // Capture the screen before the Collie window appears (Collie's own alert-level
        // windows are excluded from the render anyway). This first image is the report's
        // screenshot 1; the tester adds the rest from the form.
        draft = BugReportDraft()
        if let captured = ScreenRenderer.renderKeyWindow() {
            draft.shots = [
                BugReportShot(
                    image: captured,
                    event: CollieScreenshotEvent(date: Date(), source: .captured)
                )
            ]
        }
        guard installWindow() else { return }
        if askFirst {
            presentBanner()
        } else {
            presentSheet()
        }
    }

    /// Creates the overlay window + passthrough container. `false` when no scene exists.
    private func installWindow() -> Bool {
        guard let scene = Self.activeScene() else { return false }

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let container = PassthroughViewController()
        container.view.backgroundColor = .clear
        // The banner and screenshot mode both leave the app usable on purpose, so nothing
        // in this window should claim to be modal. See the note in `ScreenshotModeOverlay`:
        // this is necessary but not proven sufficient for VoiceOver, because Collie's
        // window sits above the app's.
        container.view.accessibilityViewIsModal = false
        window.rootViewController = container
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    private func presentBanner() {
        guard let container = window?.rootViewController as? PassthroughViewController
        else { return }

        let host = UIHostingController(
            rootView: BugReportBannerView(
                onYes: { [weak self] in self?.presentSheet() },
                onNo: { [weak self] in self?.dismissBanner() }
            )
        )
        host.view.backgroundColor = .clear
        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        host.didMove(toParent: container)
        container.passthroughHost = host.view

        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.autoDismissAfter ?? 6) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissBanner()
        }
    }

    private func dismissBanner() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        removeScreenshotOverlay()
        draft = BugReportDraft()
        window?.isHidden = true
        window = nil
    }

    private func presentSheet() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let container = window?.rootViewController else { return }

        let host = UIHostingController(
            rootView: BugReportSheet(
                draft: draft,
                onClose: { [weak self] outcome in
                    guard let self else { return }
                    // Screenshot mode is the one outcome that does NOT end the flow: the
                    // form is dismissed but the window, and everything the tester has
                    // written, stay put until they come back.
                    if case .captureScreenshots(let draft) = outcome {
                        self.draft = draft
                        self.window?.rootViewController?.dismiss(animated: true) {
                            self.enterScreenshotMode()
                        }
                        return
                    }
                    self.window?.rootViewController?.dismiss(animated: true) {
                        self.dismissBanner()
                        switch outcome {
                        case .cancelled:
                            break
                        case .sent:
                            // The report now goes to the analyst panel, not straight to
                            // Jira — so there is no issue key to show yet.
                            BugReportToast.show("Report sent — thanks!")
                        case .queued:
                            BugReportToast.show("Queued — will be sent once a connection is available")
                        case .switchTool:
                            // Invoked AFTER the Collie UI has fully closed, so the handler
                            // can safely present another diagnostics tool.
                            self.logoTapHandler?()
                        case .captureScreenshots:
                            break   // handled above
                        }
                    }
                }
            )
        )
        host.modalPresentationStyle = .formSheet
        // Hide the banner view and use the whole window for the sheet.
        if let passthrough = container as? PassthroughViewController {
            passthrough.passthroughHost?.isHidden = true
            passthrough.passthroughHost = nil
        }
        container.present(host, animated: true)
    }

    // MARK: - Screenshot mode

    /// Hands the app back to the tester with two controls on top of it: a bar that returns
    /// to the form, and a shutter that photographs whatever is on screen.
    ///
    /// The form is gone but the flow is not — `draft` holds the sentence, the name and the
    /// images already attached, and the overlay window stays up so nothing about the report
    /// can be lost while the tester walks around the app.
    private func enterScreenshotMode() {
        guard let container = window?.rootViewController as? PassthroughViewController else {
            return
        }
        let overlay = ScreenshotModeOverlay(
            onExit: { [weak self] in self?.leaveScreenshotMode() },
            onCapture: { [weak self] in self?.captureInScreenshotMode() }
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        overlay.setCount(draft.shots.count, of: maxScreenshots)
        screenshotOverlay = overlay
        // The overlay decides for itself which touches it wants; everything else goes to
        // the app, which is the whole point of the mode.
        container.transparentHost = overlay
        container.passthroughHost = nil
    }

    private func captureInScreenshotMode() {
        guard screenshotOverlay != nil else { return }
        guard draft.shots.count < maxScreenshots else { return }

        // `ScreenRenderer` only ever draws windows below `.alert`, and this overlay sits
        // above that — so the bar and the shutter cannot appear in the image, and there is
        // nothing to hide before rendering.
        guard let image = ScreenRenderer.renderKeyWindow() else {
            Collie.diag("Screenshot mode: nothing could be rendered.")
            return
        }
        draft.shots.append(
            BugReportShot(
                image: image,
                event: CollieScreenshotEvent(date: Date(), source: .captured)
            )
        )

        // One tap, one picture, straight back to the report. Staying in the mode would mean
        // the tester's only confirmation is a counter in the corner — they would have no
        // idea *what* they just attached until they left. Coming back shows the thumbnail
        // and puts the next capture one tap away, so a second screen costs nothing.
        leaveScreenshotMode()
    }

    private func leaveScreenshotMode() {
        removeScreenshotOverlay()
        presentSheet()
    }

    private func removeScreenshotOverlay() {
        screenshotOverlay?.removeFromSuperview()
        screenshotOverlay = nil
        (window?.rootViewController as? PassthroughViewController)?.transparentHost = nil
    }

    private var maxScreenshots: Int {
        Collie.bugReportService?.maxScreenshots ?? CollieConfiguration.maxScreenshotsLimit
    }

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

// MARK: - Passthrough window

/// Collie's overlay window, which must not swallow the touches it does not want.
///
/// `UIView.hitTest` returns **self** when no subview claims a point, and a `UIWindow` is a
/// view: so a window whose content declines a touch still answers "mine", and the touch
/// never reaches the app's own window underneath. That is invisible until something below
/// has to stay usable — the banner leaving the app interactive, and screenshot mode, where
/// the tester has to navigate the app being photographed. Returning `nil` for a point
/// nothing on this layer wants is what lets UIKit try the next window down.
@MainActor
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
}

// MARK: - Passthrough container

/// While the banner is visible, only touches within the banner area are captured; all
/// other touches pass through to the app underneath (the app stays interactive until the
/// modal sheet is presented).
@MainActor
private final class PassthroughViewController: UIViewController {
    /// A view whose *bounds* decide: touches inside it are captured, the rest pass through.
    /// This is the banner, which occupies a known rectangle.
    weak var passthroughHost: UIView?

    /// A full-screen view that decides for *itself*, by returning `nil` from its own
    /// `hitTest` for the parts it does not want. This is screenshot mode, which covers the
    /// screen but only wants two controls on it — a bounds check would hand it every touch
    /// and freeze the app the tester is trying to photograph.
    weak var transparentHost: UIView?

    override func loadView() {
        view = PassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (view as? PassthroughView)?.hitTestProvider = { [weak self] point, event, defaultResult in
            guard let self else { return defaultResult() }
            // If a modal is presented (sheet open): normal hit-test (whole window interactive).
            guard self.presentedViewController == nil else { return defaultResult() }
            if let host = self.passthroughHost {
                // Capture only touches that hit banner subviews; the rest go to the app.
                let converted = host.convert(point, from: self.view)
                return host.point(inside: converted, with: event) ? defaultResult() : nil
            }
            if self.transparentHost != nil {
                // The host already refused this point if it did not want it, so a result of
                // `self.view` means nothing on this layer wants the touch.
                let result = defaultResult()
                return result === self.view ? nil : result
            }
            // Nothing on this layer: pass touches through to the app underneath.
            return nil
        }
    }
}

/// While the banner is visible, passes touches outside the banner through to the app
/// underneath.
@MainActor
private final class PassthroughView: UIView {
    /// `(point, event, defaultHitTest)` → the chosen view. `defaultHitTest` is the
    /// super.hitTest result.
    var hitTestProvider: ((CGPoint, UIEvent?, () -> UIView?) -> UIView?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let defaultResult = { super.hitTest(point, with: event) }
        if let provider = hitTestProvider {
            return provider(point, event, defaultResult)
        }
        return defaultResult()
    }
}

// MARK: - Banner view (SwiftUI)

/// The Collie icon + bubble sliding in from the bottom. [Yes] [No].
@MainActor
private struct BugReportBannerView: View {

    let onYes: () -> Void
    let onNo: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 12) {
                logo
                bubble
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .offset(y: appeared ? 0 : 140)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }

    private var logo: some View {
        Image(systemName: "pawprint.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 30, height: 30)
            .foregroundColor(.white)
            .padding(17)
            .background(Circle().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotted a problem? Want to share it?")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onYes) {
                    Text("Yes")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                Button(action: onNo) {
                    Text("No")
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.primary)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
    }
}
#endif
