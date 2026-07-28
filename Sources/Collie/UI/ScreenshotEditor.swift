#if canImport(UIKit)
import PencilKit
import SwiftUI
import UIKit

/// The markup editor, opened by tapping the screenshot preview in the report sheet.
///
/// One tap in, one tap out: the screenshot and the tools are on screen the moment it opens,
/// **Done** flattens the marks into the image and returns to the form, **Cancel** throws
/// them away. Drawing is PencilKit's (`PKCanvasView` — its strokes and its undo stack); the
/// palette is Collie's own.
///
/// Two roads were tried and rejected, both verified on an iOS 26 simulator:
///
/// - **QuickLook's editing mode** (Collie 1.9.x) renders the preview out of process since
///   iOS 26 (`_EXHostView` hosting a remote scene): it opens on a blank page while that
///   scene loads, keeps its own preview page in front of markup, and its buttons live in
///   another process — three screens and a stall where the tester wanted a pen.
/// - **`PKToolPicker`** (Collie 1.8.0) docks into the `UITextEffectsWindow`, so against
///   Collie's overlay window at `.alert + 1` it is drawn 1991 levels too low — invisible.
///   Reordering the windows makes it visible, but then **the overlay stops receiving touches
///   altogether**: no drawing, no Cancel, no Done. Its palette is not worth a dead screen.
@MainActor
struct ScreenshotMarkupEditor: UIViewControllerRepresentable {

    let image: UIImage
    /// Called with the marked-up screenshot, or `nil` when the tester cancelled.
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = ScreenshotMarkupViewController(image: image, onFinish: onFinish)
        let navigation = UINavigationController(rootViewController: editor)
        navigation.navigationBar.isTranslucent = false
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {}
}

/// The screenshot with a `PKCanvasView` laid exactly over it, and the palette below.
@MainActor
final class ScreenshotMarkupViewController: UIViewController {

    private let image: UIImage
    private let onFinish: (UIImage?) -> Void

    private let imageView = UIImageView()
    private let canvas = PKCanvasView()
    private lazy var palette = MarkupPalette { [weak self] tool in
        self?.canvas.tool = tool
    }

    init(image: UIImage, onFinish: @escaping (UIImage?) -> Void) {
        self.image = image
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Mark up"
        installNavigationItems()

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Test devices rarely have a Pencil; without this the canvas ignores fingers.
        canvas.drawingPolicy = .anyInput
        // The canvas is exactly the screenshot's rect — scrolling would only shift the
        // strokes away from what they point at.
        canvas.isScrollEnabled = false
        canvas.tool = palette.currentTool
        canvas.delegate = self

        palette.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(canvas)
        view.addSubview(palette)
        installConstraints()
    }

    private func installNavigationItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Cancel",
            primaryAction: UIAction { [weak self] _ in self?.onFinish(nil) }
        )
        let done = UIBarButtonItem(
            title: "Done",
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.onFinish(self.flattened())
            }
        )
        done.style = .done
        let undo = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.backward"),
            primaryAction: UIAction { [weak self] _ in self?.canvas.undoManager?.undo() }
        )
        undo.accessibilityLabel = "Undo"
        undo.isEnabled = false
        navigationItem.rightBarButtonItems = [done, undo]
    }

    private var undoItem: UIBarButtonItem? { navigationItem.rightBarButtonItems?.last }

    /// The screenshot is laid out at its own aspect ratio — as large as fits between the
    /// navigation bar and the palette — so the image view's frame *is* the picture, and the
    /// canvas can simply match its edges.
    private func installConstraints() {
        let guide = view.safeAreaLayoutGuide
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1

        let fitWidth = imageView.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -16)
        fitWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            palette.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 12),
            palette.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -12),
            palette.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            palette.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),

            imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: aspect),
            imageView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -16),
            imageView.bottomAnchor.constraint(lessThanOrEqualTo: palette.topAnchor, constant: -12),
            fitWidth,

            canvas.topAnchor.constraint(equalTo: imageView.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: imageView.trailingAnchor)
        ])
    }

    // MARK: - Export

    /// Draws the strokes onto the screenshot at its native pixel size. The stroke overlay is
    /// rasterised at the scale matching those pixels, so marks stay crisp instead of being
    /// upscaled from the on-screen preview.
    private func flattened() -> UIImage {
        let drawing = canvas.drawing
        let bounds = canvas.bounds
        guard !drawing.strokes.isEmpty, bounds.width > 0 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let target = CGRect(origin: .zero, size: image.size)
        let overlay = drawing.image(
            from: bounds,
            scale: (image.size.width * image.scale) / bounds.width
        )
        return renderer.image { _ in
            image.draw(in: target)
            overlay.draw(in: target)
        }
    }
}

extension ScreenshotMarkupViewController: PKCanvasViewDelegate {
    nonisolated func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        MainActor.assumeIsolated {
            undoItem?.isEnabled = canvasView.undoManager?.canUndo == true
        }
    }
}

// MARK: - Palette

/// Collie's own markup palette: tool, stroke width and colour, living in the same window as
/// the canvas — which is the whole point (see `ScreenshotMarkupEditor`).
@MainActor
final class MarkupPalette: UIView {

    private enum Tool: CaseIterable {
        case pen, marker, eraser

        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .marker: "highlighter"
            case .eraser: "eraser"
            }
        }

        var label: String {
            switch self {
            case .pen: "Pen"
            case .marker: "Marker"
            case .eraser: "Eraser"
            }
        }
    }

    /// Thin / medium / thick, per tool — a marker stroke has to be far wider than a pen's to
    /// read as a highlight.
    private enum Width: CaseIterable {
        case thin, medium, thick

        var dotSize: CGFloat {
            switch self {
            case .thin: 8
            case .medium: 13
            case .thick: 18
            }
        }

        var label: String {
            switch self {
            case .thin: "thin"
            case .medium: "medium"
            case .thick: "thick"
            }
        }

        func value(marker: Bool) -> CGFloat {
            switch self {
            case .thin: marker ? 14 : 4
            case .medium: marker ? 24 : 9
            case .thick: marker ? 38 : 16
            }
        }
    }

    /// Bug-report colours: what a tester circles a defect with. Red first — it is what
    /// nearly every annotation uses.
    private static let colors: [(name: String, color: UIColor)] = [
        ("Red", .systemRed),
        ("Orange", .systemOrange),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Blue", .systemBlue),
        ("Black", .label)
    ]

    private let onToolChange: (PKTool) -> Void
    private var tool: Tool = .pen
    private var width: Width = .medium
    private var colorIndex = 0

    private var toolButtons: [(tool: Tool, button: UIButton)] = []
    private var widthButtons: [(width: Width, button: UIButton)] = []
    private var colorButtons: [UIButton] = []

    init(onToolChange: @escaping (PKTool) -> Void) {
        self.onToolChange = onToolChange
        super.init(frame: .zero)
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var currentTool: PKTool { makeTool() }

    // MARK: Layout

    private func build() {
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerRadius = 26
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        addSubview(background)

        let tools = UIStackView(arrangedSubviews: Tool.allCases.map { tool in
            let button = iconButton(symbol: tool.symbol, label: tool.label) { [weak self] in
                self?.select(tool: tool)
            }
            toolButtons.append((tool, button))
            return button
        })
        tools.spacing = 2

        let widths = UIStackView(arrangedSubviews: Width.allCases.map { width in
            let button = dotButton(size: width.dotSize, label: width.label) { [weak self] in
                self?.select(width: width)
            }
            widthButtons.append((width, button))
            return button
        })
        widths.spacing = 0
        widths.alignment = .center

        let topRow = UIStackView(arrangedSubviews: [tools, separator(), widths])
        topRow.alignment = .center
        topRow.spacing = 10

        let colors = UIStackView(arrangedSubviews: Self.colors.enumerated().map { index, entry in
            let button = swatchButton(color: entry.color, label: entry.name) { [weak self] in
                self?.select(colorIndex: index)
            }
            colorButtons.append(button)
            return button
        })
        colors.spacing = 10

        let rows = UIStackView(arrangedSubviews: [topRow, colors])
        rows.axis = .vertical
        rows.alignment = .center
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    private func iconButton(symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        return button
    }

    private func dotButton(size: CGFloat, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: size)
        )
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 5, bottom: 6, trailing: 5)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = "Stroke width \(label)"
        return button
    }

    private func swatchButton(color: UIColor, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(primaryAction: UIAction { _ in action() })
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = color
        button.layer.cornerRadius = 15
        button.layer.borderColor = UIColor.systemBackground.cgColor
        button.accessibilityLabel = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return button
    }

    private func separator() -> UIView {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = .separator
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 24)
        ])
        return line
    }

    // MARK: Selection

    private func select(tool: Tool) {
        self.tool = tool
        refresh()
    }

    private func select(width: Width) {
        self.width = width
        refresh()
    }

    private func select(colorIndex: Int) {
        self.colorIndex = colorIndex
        // Picking a colour while erasing means the tester wants to draw again.
        if tool == .eraser { tool = .pen }
        refresh()
    }

    private func refresh() {
        let color = Self.colors[colorIndex].color
        for (candidate, button) in toolButtons {
            let selected = candidate == tool
            button.configuration?.baseForegroundColor = selected ? .white : .label
            button.configuration?.background.backgroundColor = selected ? color : .clear
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
        for (candidate, button) in widthButtons {
            let selected = candidate == width
            button.configuration?.baseForegroundColor = selected ? color : .tertiaryLabel
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
        for (index, button) in colorButtons.enumerated() {
            let selected = index == colorIndex && tool != .eraser
            button.layer.borderWidth = selected ? 3 : 0
            button.transform = selected ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
        onToolChange(makeTool())
    }

    private func makeTool() -> PKTool {
        let color = Self.colors[colorIndex].color
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: color, width: width.value(marker: false))
        case .marker:
            return PKInkingTool(.marker, color: color, width: width.value(marker: true))
        case .eraser:
            return PKEraserTool(.bitmap)
        }
    }
}
#endif
