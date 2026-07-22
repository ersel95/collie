#if canImport(UIKit)
import UIKit

/// Short-lived result toast ("PROJ-123 created" / "Queued") — on a separate temporary
/// `UIWindow`, never touching the app.
@MainActor
enum BugReportToast {

    private static var window: UIWindow?

    static func show(_ message: String, duration: TimeInterval = 2) {
        guard let scene = activeScene() else { return }
        dismiss()

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 2
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let container = UIViewController()
        container.view.backgroundColor = .clear
        window.rootViewController = container
        window.makeKeyAndVisible()
        Self.window = window

        let label = PaddedLabel()
        label.text = message
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alpha = 0
        container.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.bottomAnchor, constant: -40)
        ])

        UIView.animate(withDuration: 0.25, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: duration, options: []) {
                label.alpha = 0
            } completion: { _ in
                dismiss()
            }
        }
    }

    private static func dismiss() {
        window?.isHidden = true
        window = nil
    }

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

@MainActor
private final class PaddedLabel: UILabel {
    private let inset = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + inset.left + inset.right,
                      height: size.height + inset.top + inset.bottom)
    }
}
#endif
