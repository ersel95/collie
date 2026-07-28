#if canImport(UIKit)
import PencilKit
import SwiftUI
import UIKit

/// Full-screen markup editor for the captured screenshot, opened by tapping the preview
/// in the report sheet.
///
/// Built on PencilKit so the tester gets the same tools as the system markup screen —
/// pen/marker/eraser, colours, undo — from `PKToolPicker`, with finger input enabled
/// (`drawingPolicy = .anyInput`); test devices rarely have an Apple Pencil.
///
/// **Save** flattens the strokes onto the screenshot at its native pixel size and hands
/// the result back, so the rest of the flow (JPEG encoding, upload) carries the annotated
/// image and never sees the original. **Cancel** discards the strokes.
@MainActor
struct ScreenshotEditor: View {

    let image: UIImage
    let onCancel: () -> Void
    let onSave: (UIImage) -> Void

    /// Bridge to the live `PKCanvasView` — the toolbar buttons and the export act on it
    /// directly, which keeps PencilKit's own undo stack as the source of truth.
    @State private var handle = MarkupHandle()
    /// Drives the enabled state of Undo/Clear; updated by the canvas delegate.
    @State private var strokeCount = 0

    /// Room reserved at the bottom for the floating tool picker, so it never covers the
    /// part of the screenshot being marked up.
    private let toolPickerReserve: CGFloat = 96

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                let canvasSize = fittedSize(in: CGSize(
                    width: geo.size.width,
                    height: max(geo.size.height - toolPickerReserve, 1)
                ))
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: canvasSize.width, height: canvasSize.height)
                        MarkupCanvas(handle: handle) { count in
                            strokeCount = count
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Mark up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        handle.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(strokeCount == 0)
                    .accessibilityLabel("Undo")

                    Button {
                        handle.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(strokeCount == 0)
                    .accessibilityLabel("Clear all marks")

                    Button("Save") { onSave(flattened()) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Geometry

    /// The aspect-fit rect the screenshot occupies — the canvas matches it exactly, so a
    /// stroke lands where the tester drew it.
    private func fittedSize(in available: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return available }
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    // MARK: - Export

    /// Draws the strokes onto the screenshot at its native pixel size. The stroke overlay
    /// is rasterised at the scale that matches those pixels, so marks stay crisp instead of
    /// being upscaled from the on-screen preview.
    private func flattened() -> UIImage {
        guard let drawing = handle.canvas?.drawing, !drawing.strokes.isEmpty,
              let canvasBounds = handle.canvas?.bounds, canvasBounds.width > 0
        else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        let target = CGRect(origin: .zero, size: image.size)
        let overlayScale = (image.size.width * image.scale) / canvasBounds.width
        let overlay = drawing.image(from: canvasBounds, scale: overlayScale)

        return renderer.image { _ in
            image.draw(in: target)
            overlay.draw(in: target)
        }
    }
}

// MARK: - Canvas bridge

/// Holds the live canvas and its tool picker for the SwiftUI layer. A reference type on
/// purpose: the toolbar needs to reach the canvas that PencilKit owns.
@MainActor
final class MarkupHandle {
    weak var canvas: PKCanvasView?
    /// Kept alive for as long as the editor is up — a released picker takes the palette
    /// with it.
    var toolPicker: PKToolPicker?

    func undo() {
        canvas?.undoManager?.undo()
    }

    func clear() {
        guard let canvas else { return }
        // Through the undo manager rather than assigning an empty drawing, so a cleared
        // markup can still be undone.
        canvas.undoManager?.beginUndoGrouping()
        canvas.drawing = PKDrawing()
        canvas.undoManager?.endUndoGrouping()
    }
}

/// The PencilKit canvas laid over the screenshot.
private struct MarkupCanvas: UIViewRepresentable {

    let handle: MarkupHandle
    /// Reports the stroke count after every change (enables/disables Undo and Clear).
    let onDrawingChange: (Int) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = WindowAwareCanvas()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Test devices rarely have a Pencil; without this the canvas ignores fingers.
        canvas.drawingPolicy = .anyInput
        // The canvas is exactly the image rect — scrolling would only shift the strokes
        // away from what is underneath them.
        canvas.isScrollEnabled = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        // A usable default, so marking up works even if the tool picker never appears.
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 8)
        canvas.delegate = context.coordinator
        canvas.onAttachToWindow = { [weak canvas] in
            guard let canvas else { return }
            context.coordinator.presentToolPicker(for: canvas)
        }
        handle.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // The drawing lives in the canvas, not in SwiftUI state — nothing to push back.
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.dismissToolPicker(for: canvas)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle, onDrawingChange: onDrawingChange)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let handle: MarkupHandle
        private let onDrawingChange: (Int) -> Void

        init(handle: MarkupHandle, onDrawingChange: @escaping (Int) -> Void) {
            self.handle = handle
            self.onDrawingChange = onDrawingChange
        }

        func presentToolPicker(for canvas: PKCanvasView) {
            let picker = handle.toolPicker ?? PKToolPicker()
            handle.toolPicker = picker
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }

        func dismissToolPicker(for canvas: PKCanvasView) {
            handle.toolPicker?.setVisible(false, forFirstResponder: canvas)
            handle.toolPicker?.removeObserver(canvas)
            handle.toolPicker = nil
        }

        nonisolated func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            MainActor.assumeIsolated {
                onDrawingChange(canvasView.drawing.strokes.count)
            }
        }
    }
}

/// `PKCanvasView` that reports when it lands in a window — the tool picker can only be
/// shown once the canvas can become first responder.
private final class WindowAwareCanvas: PKCanvasView {
    var onAttachToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        onAttachToWindow?()
    }
}
#endif
