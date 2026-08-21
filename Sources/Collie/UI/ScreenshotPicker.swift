#if canImport(UIKit)
import PhotosUI
import SwiftUI
import UIKit

/// The system photo picker, used to attach screenshots the tester took before opening the
/// form — the state two screens back, the notification that started it, the other app the
/// data came from. Collie captures the moment of the shake; this is how everything else
/// gets into the same report.
///
/// **`PHPickerViewController`, not `UIImagePickerController`.** The picker runs out of
/// process and hands back only the items the tester chose, so it needs **no**
/// photo-library permission and raises no prompt. That is not a convenience: Collie must
/// never ask for a permission (`AGENTS.md`) — a bug reporter that asks for the photo
/// library teaches testers to decline, and a request without a usage description in the
/// host's Info.plist crashes the app it was meant to diagnose.
///
/// Unlike QuickLook's editing mode — the out-of-process editor that had to be removed from
/// the markup path — nothing here is drawn *over* by Collie: the picker is presented as a
/// sheet from Collie's own window and owns the whole screen while it is up.
@MainActor
struct ScreenshotPicker: UIViewControllerRepresentable {

    /// How many more images the form can take. The picker enforces it itself, so the
    /// tester is stopped while choosing rather than silently trimmed afterwards.
    let limit: Int

    /// Called with the chosen images, already decoded, in the order they were picked.
    /// Empty when the tester cancelled or nothing could be loaded — the caller closes the
    /// picker either way.
    let onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = max(1, limit)
        // The tester's picking order is the attachment order, and the attachment order is
        // what the analyst scrolls through. Without this the system returns library order,
        // which is chronological and has nothing to do with the story being told.
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(limit: limit, onFinish: onFinish)
    }

    /// Loads the picked items and reports them back on the main actor.
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let limit: Int
        private let onFinish: @MainActor ([UIImage]) -> Void

        init(limit: Int, onFinish: @escaping @MainActor ([UIImage]) -> Void) {
            self.limit = limit
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let providers = results.prefix(max(0, limit)).map(\.itemProvider)
            Task { [onFinish] in
                var images: [UIImage] = []
                for provider in providers {
                    // A provider that cannot produce an image is skipped, not fatal: the
                    // rest of the selection still reaches the form.
                    if let image = await Self.loadImage(from: provider) { images.append(image) }
                }
                await MainActor.run { onFinish(images) }
            }
        }

        private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
            guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
            return await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }
    }
}
#endif
