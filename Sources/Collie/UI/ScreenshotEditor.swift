#if canImport(UIKit)
import QuickLook
import SwiftUI
import UIKit

/// The **system** markup editor, opened by tapping the screenshot preview in the report
/// sheet.
///
/// This is QuickLook's editing mode — the very same markup UI iOS shows for a screenshot
/// or a file: the PencilKit palette (pen, marker, pencil, ruler, eraser, colours) *plus*
/// the "+" menu that only Markup has (text, shapes, signature, magnifier, opacity). Using
/// it instead of a hand-built canvas means the tester gets the editor they already know,
/// and it keeps up with whatever Apple ships next.
///
/// The screenshot is written to a temporary file and previewed in `.updateContents` mode,
/// so Markup saves the flattened result straight back over that file. The sheet then
/// reloads it and the rest of the flow (JPEG encoding, upload) carries the annotated
/// image, never the original.
///
/// The two pages QuickLook adds around markup are skipped, so one tap on the preview is
/// one markup session: it opens **straight into** markup (`MarkupEntry`), and closes on
/// the markup Done rather than dropping the tester back on QuickLook's preview page. Both
/// are best-effort — if either fails, the plain QuickLook navigation is still there.
@MainActor
struct ScreenshotMarkupPreview: UIViewControllerRepresentable {

    /// The temporary file Markup edits in place.
    let fileURL: URL
    /// Called on the main actor once the preview closes.
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> MarkupContainerViewController {
        let container = MarkupContainerViewController()
        // Visible for one frame while QuickLook animates away — a plain background reads as
        // the sheet's own page rather than as a black flash.
        container.view.backgroundColor = .systemBackground
        container.onReady = { [weak container] in
            guard let container else { return }
            let preview = QLPreviewController()
            preview.dataSource = context.coordinator
            preview.delegate = context.coordinator
            preview.modalPresentationStyle = .fullScreen
            // Presented rather than embedded: QuickLook only puts its own Done button up
            // when it owns the presentation.
            container.present(preview, animated: false) {
                context.coordinator.previewDidPresent(preview)
            }
        }
        return container
    }

    func updateUIViewController(_ container: MarkupContainerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, onDismiss: onDismiss)
    }

    /// ⚠️ QuickLook calls these back from **whatever queue it likes** — the save path runs
    /// on an `NSFileCoordinator` operation queue, not the main one. So every method here is
    /// `nonisolated` and touches only immutable state; anything that has to reach the UI
    /// hops to the main queue first. `MainActor.assumeIsolated` in these callbacks traps
    /// the process (it did: SIGTRAP on Done, Collie 1.9.0).
    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {

        private nonisolated let item: MarkupItem
        private let onDismiss: () -> Void
        private weak var preview: QLPreviewController?
        /// Both the delegate callback and our own dismissal lead here; whoever arrives
        /// first wins.
        private var didFinish = false

        init(fileURL: URL, onDismiss: @escaping () -> Void) {
            self.item = MarkupItem(url: fileURL)
            self.onDismiss = onDismiss
        }

        /// Skips QuickLook's preview page — the tester tapped the screenshot to draw on it,
        /// so that page is a dead click.
        func previewDidPresent(_ preview: QLPreviewController) {
            self.preview = preview
            MarkupEntry.open(in: preview)
        }

        /// Markup saved (the tester tapped Done in the editor): close the whole thing
        /// instead of leaving them on QuickLook's preview page, one more Done away from the
        /// form they came from.
        private func finishAfterSave() {
            guard !didFinish, let preview, preview.presentingViewController != nil else { return }
            didFinish = true
            preview.dismiss(animated: true) { [weak self] in
                MainActor.assumeIsolated { self?.onDismiss() }
            }
        }

        nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        nonisolated func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            item
        }

        /// Turns the plain preview into an editor: this is what puts the markup button in
        /// the navigation bar. `.updateContents` writes the edits back over our temporary
        /// file, so there is no second copy to track.
        nonisolated func previewController(
            _ controller: QLPreviewController,
            editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .updateContents
        }

        nonisolated func previewController(
            _ controller: QLPreviewController,
            didUpdateContentsOf previewItem: QLPreviewItem
        ) {
            closeAfterSave()
        }

        /// QuickLook could not write back in place (permissions, disk) and saved a copy
        /// elsewhere — move it over our file so the sheet still picks the edits up.
        /// `FileManager` is thread-safe, so this needs no hop.
        nonisolated func previewController(
            _ controller: QLPreviewController,
            didSaveEditedCopyOf previewItem: QLPreviewItem,
            at modifiedContentsURL: URL
        ) {
            if let destination = item.previewItemURL {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: modifiedContentsURL, to: destination)
            }
            closeAfterSave()
        }

        nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
            // Explicit hop rather than an isolation assumption: this one does arrive on the
            // main queue today, but nothing in the API promises it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.didFinish else { return }
                    self.didFinish = true
                    self.onDismiss()
                }
            }
        }

        /// The save callbacks arrive off the main queue and right as QuickLook is animating
        /// out of markup — hop, and let that animation land before dismissing on top of it.
        private nonisolated func closeAfterSave() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated { self.finishAfterSave() }
            }
        }
    }
}

/// Hosts the QuickLook presentation. Presenting from `viewDidAppear` rather than from
/// `updateUIViewController`: while SwiftUI's cover is still animating in, the container
/// is not in a window yet and the presentation would be dropped.
@MainActor
final class MarkupContainerViewController: UIViewController {

    var onReady: (() -> Void)?
    private var didPresent = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent else { return }
        didPresent = true
        onReady?()
    }
}

// MARK: - Opening straight into markup

/// Opens QuickLook directly in markup, skipping its preview page.
///
/// There is no API for this: editing begins when the tester taps the markup button
/// QuickLook puts in its overlay. So that button is located and invoked exactly as a tap
/// would — identified by its **accessibility identifier** (`QLOverlayMarkupButton`) or, for
/// a bar-button layout, by the **selector** it carries (`enableMarkupMode:`). Both are
/// language-independent, unlike the button's label.
///
/// The button only exists once the item has finished loading, hence the short retry. After
/// that this gives up quietly and the tester opens markup themselves — which is simply the
/// behaviour Collie shipped in 1.9.x.
@MainActor
enum MarkupEntry {

    private static let retryInterval: TimeInterval = 0.1
    private static let maxAttempts = 20

    static func open(in preview: QLPreviewController, attempt: Int = 0) {
        // Gone already (dismissed while loading): nothing left to open.
        guard preview.presentingViewController != nil else { return }
        if fireControl(in: preview.view) || fireBarItem(in: preview.view) { return }
        guard attempt < maxAttempts else {
            Collie.diag("Markup: QuickLook's markup button was not found — the tester opens it.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            MainActor.assumeIsolated { open(in: preview, attempt: attempt + 1) }
        }
    }

    // MARK: Overlay button

    private static func fireControl(in view: UIView) -> Bool {
        guard let control = markupControl(in: view) else { return false }
        control.sendActions(for: .touchUpInside)
        return true
    }

    private static func markupControl(in view: UIView) -> UIControl? {
        if let control = view as? UIControl, control.isEnabled,
           isMarkupIdentifier(control.accessibilityIdentifier) {
            return control
        }
        for subview in view.subviews {
            if let found = markupControl(in: subview) { return found }
        }
        return nil
    }

    // MARK: Bar button

    private static func fireBarItem(in view: UIView) -> Bool {
        guard let item = markupItem(in: view),
              item.isEnabled,
              let action = item.action,
              let target = item.target as? NSObject,
              target.responds(to: action)
        else { return false }
        _ = target.perform(action, with: item)
        return true
    }

    private static func markupItem(in view: UIView) -> UIBarButtonItem? {
        var candidates: [UIBarButtonItem] = []
        if let bar = view as? UINavigationBar {
            candidates = (bar.items ?? []).flatMap {
                ($0.rightBarButtonItems ?? []) + ($0.leftBarButtonItems ?? [])
            }
        } else if let toolbar = view as? UIToolbar {
            candidates = toolbar.items ?? []
        }
        if let match = candidates.first(where: {
            isMarkupIdentifier($0.accessibilityIdentifier) || isMarkupAction($0.action)
        }) {
            return match
        }
        for subview in view.subviews {
            if let found = markupItem(in: subview) { return found }
        }
        return nil
    }

    // MARK: Matching

    private static func isMarkupIdentifier(_ identifier: String?) -> Bool {
        identifier?.lowercased().contains("markup") == true
    }

    /// The buttons sharing that bar are Done, Share, Open-in and List; none of their
    /// selectors carries any of these words, so a match is unambiguous.
    private static func isMarkupAction(_ selector: Selector?) -> Bool {
        guard let selector else { return false }
        let name = NSStringFromSelector(selector).lowercased()
        return name.contains("markup") || name.contains("annotat")
    }
}

/// A file-backed preview item. QuickLook needs an object here, not a bare URL.
///
/// `@unchecked Sendable`: both properties are immutable value types, and QuickLook reads
/// the item from whichever queue it likes — an `NSObject` subclass cannot be inferred
/// `Sendable` on its own.
private final class MarkupItem: NSObject, QLPreviewItem, @unchecked Sendable {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL) {
        self.previewItemURL = url
        self.previewItemTitle = "Screenshot"
    }
}

// MARK: - Temporary file handling

/// Moves the screenshot to and from the temporary file QuickLook edits in place.
@MainActor
enum ScreenshotMarkupFile {

    /// Writes the screenshot out as PNG (lossless: the tester may go in and out of markup
    /// several times before sending). `nil` when it cannot be written — the caller then
    /// simply keeps the preview non-interactive.
    static func write(_ image: UIImage) -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collie-markup-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Collie.diag("Markup: could not write the temporary screenshot — \(error)")
            return nil
        }
    }

    /// Reads the marked-up file back, restoring the scale of the original (a PNG on disk
    /// carries none), so the preview and the upload keep the geometry they started with.
    static func read(_ url: URL, matching original: UIImage) -> UIImage? {
        guard let data = try? Data(contentsOf: url), let decoded = UIImage(data: data)
        else { return nil }
        guard let cgImage = decoded.cgImage else { return decoded }
        return UIImage(cgImage: cgImage, scale: original.scale, orientation: .up)
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
