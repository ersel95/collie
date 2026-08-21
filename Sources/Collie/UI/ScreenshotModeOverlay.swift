#if canImport(UIKit)
import UIKit

/// **Screenshot mode**: the report form steps aside so the tester can walk back through the
/// app and photograph the screens that matter, one tap each.
///
/// A bug is rarely one screen. The shake happens where the tester noticed the problem, but
/// what an analyst needs is often two screens back — the list they came from, the form they
/// filled, the notification that started it. Describing that in prose is what testers do
/// when the tool gives them one picture; this is the tool giving them five.
///
/// Two controls and nothing else on screen:
/// - a **bar** across the top, so it is never ambiguous that the app is in a mode, and one
///   tap on it goes back to the form;
/// - a **shutter** in the bottom-right corner, with the count beside it. One tap takes the
///   picture and returns to the report — the tester sees what they attached instead of a
///   counter ticking up, and the next capture is one tap away from there.
///
/// Everything between them belongs to the host app: this view returns `nil` from `hitTest`
/// for any point that is not one of its own controls, so the tester scrolls, taps and
/// navigates exactly as they would without Collie on screen. That is the whole point — the
/// screen being photographed has to be reachable.
///
/// The render itself needs no cooperation from this view: `ScreenRenderer` only ever draws
/// windows below `.alert`, and Collie's overlay window sits above it, so neither the bar nor
/// the shutter can appear in a captured image.
@MainActor
final class ScreenshotModeOverlay: UIView {

    /// Tapped the bar — leave the mode and go back to the form.
    private let onExit: () -> Void
    /// Tapped the shutter — capture what is on screen right now.
    private let onCapture: () -> Void

    /// A plain view rather than a `UIButton`: a button's `Configuration` owns its title's
    /// font through a key path that Swift 6 rejects as non-Sendable, and the bar needs no
    /// button behaviour beyond "tap me".
    private let bar = UIView()
    private let shutter = UIButton(type: .system)
    private let counter = UILabel()

    init(onExit: @escaping () -> Void, onCapture: @escaping () -> Void) {
        self.onExit = onExit
        self.onCapture = onCapture
        super.init(frame: .zero)
        backgroundColor = .clear
        // This mode exists so the tester can navigate the host app, so nothing here should
        // claim to be modal. ⚠️ This is necessary but **not verified sufficient**: Collie's
        // controls live in a window above the app's, and an assistive technology may still
        // present only the topmost window whatever a view inside it says. Driving the mode
        // with VoiceOver actually turned on is the check that would settle it, and it has
        // not been done — treat screen-reader use of screenshot mode as unproven.
        accessibilityViewIsModal = false
        installBar()
        installShutter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Touch routing

    /// Only the bar and the shutter take touches; everything else reaches the app below.
    ///
    /// Returning `self` for the empty space would swallow every tap and freeze the app the
    /// tester is trying to photograph — the mode would be unusable, and it would look like
    /// the host had hung.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }

    /// The controls that must receive touches, for the container's own hit-test.
    var interactiveViews: [UIView] { [bar, shutter] }

    // MARK: - State

    /// Updates the "n/5" pill. Called after every capture.
    func setCount(_ count: Int, of limit: Int) {
        counter.text = "\(count)/\(limit)"
        let isFull = count >= limit
        shutter.isEnabled = !isFull
        shutter.alpha = isFull ? 0.5 : 1
    }

    // MARK: - Subviews

    private func installBar() {
        bar.backgroundColor = .systemRed
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isUserInteractionEnabled = true
        bar.accessibilityLabel = "Leave screenshot mode"
        bar.accessibilityTraits = .button
        bar.isAccessibilityElement = true
        bar.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(barTapped))
        )
        addSubview(bar)

        let label = UILabel()
        label.text = "Screenshot mode — tap to go back to your report"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(label)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),

            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: bar.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -9)
        ])
    }

    @objc private func barTapped() {
        onExit()
    }

    private func installShutter() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "camera.fill")
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        configuration.background.cornerRadius = 32
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        shutter.configuration = configuration
        shutter.accessibilityLabel = "Take a screenshot"
        shutter.layer.shadowColor = UIColor.black.cgColor
        shutter.layer.shadowOpacity = 0.25
        shutter.layer.shadowRadius = 8
        shutter.layer.shadowOffset = CGSize(width: 0, height: 3)
        shutter.addAction(UIAction { [weak self] _ in self?.onCapture() }, for: .touchUpInside)
        shutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shutter)

        counter.font = .systemFont(ofSize: 12, weight: .bold)
        counter.textColor = .white
        counter.textAlignment = .center
        counter.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        counter.layer.cornerRadius = 10
        counter.layer.masksToBounds = true
        counter.isUserInteractionEnabled = false
        counter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(counter)

        NSLayoutConstraint.activate([
            shutter.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            shutter.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -28),
            shutter.widthAnchor.constraint(equalToConstant: 64),
            shutter.heightAnchor.constraint(equalToConstant: 64),

            counter.centerXAnchor.constraint(equalTo: shutter.centerXAnchor),
            counter.bottomAnchor.constraint(equalTo: shutter.topAnchor, constant: -8),
            counter.widthAnchor.constraint(equalToConstant: 40),
            counter.heightAnchor.constraint(equalToConstant: 20)
        ])
    }
}
#endif
