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
            container.present(preview, animated: false)
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

        init(fileURL: URL, onDismiss: @escaping () -> Void) {
            self.item = MarkupItem(url: fileURL)
            self.onDismiss = onDismiss
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

        /// QuickLook could not write back in place (permissions, disk) and saved a copy
        /// elsewhere — move it over our file so the sheet still picks the edits up.
        /// `FileManager` is thread-safe, so this needs no hop.
        nonisolated func previewController(
            _ controller: QLPreviewController,
            didSaveEditedCopyOf previewItem: QLPreviewItem,
            at modifiedContentsURL: URL
        ) {
            guard let destination = item.previewItemURL else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: modifiedContentsURL, to: destination)
        }

        nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
            // Explicit hop rather than an isolation assumption: this one does arrive on the
            // main queue today, but nothing in the API promises it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onDismiss() }
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
