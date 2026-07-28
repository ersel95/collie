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
    private var pendingScreenshot: UIImage?

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
        ShakeDetector.install()
        // Start battery monitoring + the network monitor early so the first report has
        // populated telemetry.
        CollieTelemetryCollector.prepare()
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
        // windows are excluded from the render anyway).
        pendingScreenshot = ScreenRenderer.renderKeyWindow()
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

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let container = PassthroughViewController()
        container.view.backgroundColor = .clear
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
        window?.isHidden = true
        window = nil
    }

    private func presentSheet() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let container = window?.rootViewController else { return }

        let screenshot = pendingScreenshot
        let host = UIHostingController(
            rootView: BugReportSheet(
                screenshot: screenshot,
                onClose: { [weak self] outcome in
                    self?.window?.rootViewController?.dismiss(animated: true) {
                        self?.dismissBanner()
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
                            self?.logoTapHandler?()
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

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

// MARK: - Passthrough container

/// While the banner is visible, only touches within the banner area are captured; all
/// other touches pass through to the app underneath (the app stays interactive until the
/// modal sheet is presented).
@MainActor
private final class PassthroughViewController: UIViewController {
    weak var passthroughHost: UIView?

    override func loadView() {
        view = PassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (view as? PassthroughView)?.hitTestProvider = { [weak self] point, event, defaultResult in
            guard let self else { return defaultResult() }
            // If a modal is presented (sheet open): normal hit-test (whole window interactive).
            guard self.presentedViewController == nil else { return defaultResult() }
            // No banner view: pass touches through to the app underneath.
            guard let host = self.passthroughHost else { return nil }
            // Capture only touches that hit banner subviews; the rest go to the app.
            let converted = host.convert(point, from: self.view)
            return host.point(inside: converted, with: event) ? defaultResult() : nil
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
