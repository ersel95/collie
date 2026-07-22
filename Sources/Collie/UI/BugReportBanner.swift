#if canImport(UIKit)
import UIKit
import SwiftUI

/// The bug-reporter UI orchestrator: when a screenshot is detected, shows a bubble from
/// the bottom inside a **separate `UIWindow`** (never touching the app's hierarchy);
/// **Yes** → presents the report sheet; finally shows a "PROJ-123 created" / "Queued"
/// toast.
@MainActor
final class BugReportBanner {

    static let shared = BugReportBanner()

    private var window: UIWindow?
    private var screenshotObserver: NSObjectProtocol?
    private var autoDismissTask: Task<Void, Never>?
    private var pendingScreenshot: UIImage?

    /// The banner auto-dismisses after a few seconds without interaction.
    private let autoDismissAfter: TimeInterval = 6

    private init() {}

    // MARK: - Setup (triggered by Collie.configure)

    /// Installs the screenshot detector + observer. Called **only when the bug-reporter
    /// opt-in is on**. Idempotent.
    func install() {
        guard screenshotObserver == nil else { return }
        ScreenshotDetector.shared.install()
        // Start battery monitoring + the network monitor early so the first report has
        // populated telemetry.
        CollieTelemetryCollector.prepare()
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: .collieScreenshotCaptured,
            object: nil,
            queue: .main
        ) { note in
            let image = note.object as? UIImage
            MainActor.assumeIsolated {
                BugReportBanner.shared.handleScreenshot(image)
            }
        }
    }

    // MARK: - Flow

    private func handleScreenshot(_ image: UIImage?) {
        // Gate: don't show the banner when the service is absent (opt-in off) or capture
        // is disabled.
        guard Collie.bugReportService?.isCaptureEnabled == true else { return }
        // Don't repeat while a banner/sheet is already visible.
        guard window == nil else { return }
        pendingScreenshot = image
        presentBanner()
    }

    private func presentBanner() {
        guard let scene = Self.activeScene() else { return }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let container = PassthroughViewController()
        container.view.backgroundColor = .clear
        window.rootViewController = container
        window.makeKeyAndVisible()
        self.window = window

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
                        case .sent(let issueKey):
                            BugReportToast.show("\(issueKey) created")
                        case .queued:
                            BugReportToast.show("Queued — will be sent once a connection is available")
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
