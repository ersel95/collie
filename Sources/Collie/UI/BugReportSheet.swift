#if canImport(UIKit)
import SwiftUI
import UIKit

/// The bug report screen (SwiftUI). Presented from the banner's **Yes**.
///
/// - One field: **"What happened?"** → `whatHappened`.
/// - On first use (no stored name) a **name** field is shown as well (one time only).
/// - Tapping the screenshot preview opens `ScreenshotEditor` (PencilKit markup); saving
///   there replaces the image the rest of the flow uses.
/// - **Send** button: active once the description (after trimming) and, if required,
///   the name are filled.
/// - Send → loading → report uploaded to the panel: closes with the report id on success; on a
///   transient failure the report is queued and the sheet closes with "queued"; on a
///   permanent failure an inline error is shown.
@MainActor
struct BugReportSheet: View {

    /// Why the sheet closed (the banner shows a toast accordingly).
    enum Outcome {
        case cancelled
        case sent(reportID: String)
        case queued
        /// The logo in the navigation bar was tapped: close the Collie UI, then invoke
        /// the host's switch-tool handler.
        case switchTool
    }

    enum SubmitState: Equatable {
        case idle
        case sending
        case failed(String)
    }

    /// Fields, in keyboard/focus order.
    private enum Field: Hashable {
        case name, happened
    }

    /// Called when the sheet closes.
    let onClose: (_ outcome: Outcome) -> Void

    /// The captured screenshot, replaced in place when the tester marks it up — what is
    /// uploaded is whatever this holds at send time.
    @State private var screenshot: UIImage?
    @State private var whatHappened: String = ""
    @State private var testerName: String = ""
    @State private var state: SubmitState = .idle
    @State private var isMarkingUp = false
    @FocusState private var focusedField: Field?

    init(screenshot: UIImage?, onClose: @escaping (_ outcome: Outcome) -> Void) {
        _screenshot = State(initialValue: screenshot)
        self.onClose = onClose
    }

    private let requiresName: Bool = !CollieDeviceIdentity.hasStoredName
    /// Whether the host registered a switch-tool handler (`Collie.onLogoTap`); when it
    /// did, the nav-bar logo becomes a button.
    private let hasLogoTapHandler: Bool = BugReportBanner.shared.logoTapHandler != nil

    /// Focus order of the visible fields (the name only exists on first use).
    private var fieldOrder: [Field] {
        (requiresName ? [Field.name] : []) + [.happened]
    }

    private var isLastFieldFocused: Bool {
        guard let f = focusedField, let i = fieldOrder.firstIndex(of: f) else { return false }
        return i == fieldOrder.count - 1
    }

    /// Move to the next field; dismiss the keyboard on the last one.
    private func focusNext() {
        guard let f = focusedField, let i = fieldOrder.firstIndex(of: f) else {
            focusedField = fieldOrder.first
            return
        }
        focusedField = (i + 1 < fieldOrder.count) ? fieldOrder[i + 1] : nil
    }

    private var trimmedHappened: String { whatHappened.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { testerName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSend: Bool {
        guard !trimmedHappened.isEmpty else { return false }
        if requiresName, trimmedName.isEmpty { return false }
        return state != .sending
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if requiresName {
                            nameSection.id(Field.name)
                        }
                        fieldSection(
                            title: "What happened?",
                            placeholder: "Describe the problem you ran into…",
                            text: $whatHappened,
                            field: .happened
                        )
                        .id(Field.happened)
                        if case let .failed(message) = state {
                            errorBanner(message)
                        }
                        // Below the inputs on purpose: the keyboard covers the bottom of
                        // the sheet, and what the tester needs to reach is the text field,
                        // not the thumbnail.
                        if let screenshot {
                            previewSection(screenshot)
                        }
                        // Bottom spacer so the keyboard doesn't cover the last field.
                        Color.clear.frame(height: 8)
                    }
                    .padding(20)
                }
                // When focus changes, scroll the focused field above the keyboard.
                .onChange(of: focusedField) { _, newValue in
                    guard let f = newValue else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(f, anchor: .center)
                    }
                }
            }
            .navigationTitle("Report a Problem")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    logoItem
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose(.cancelled) }
                        .disabled(state == .sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    sendButton
                }
                // Keyboard navigation: "Done" on the last field, "Next" otherwise.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    if isLastFieldFocused {
                        Button("Done") { focusedField = nil }
                    } else {
                        Button("Next") { focusNext() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(state == .sending)
        .fullScreenCover(isPresented: $isMarkingUp) {
            if let screenshot {
                ScreenshotEditor(
                    image: screenshot,
                    onCancel: { isMarkingUp = false },
                    onSave: { edited in
                        self.screenshot = edited
                        isMarkingUp = false
                    }
                )
            }
        }
    }

    // MARK: - Sections

    /// The Collie logo in the navigation bar. When the host registered a switch-tool
    /// handler, it becomes a button: tapping it closes the Collie UI and hands off to
    /// the other tool (the handler runs after the UI has fully closed).
    @ViewBuilder
    private var logoItem: some View {
        let logo = Image(systemName: "pawprint.fill")
            .resizable()
            .scaledToFit()
            .frame(height: 22)
            .foregroundStyle(.primary)
        if hasLogoTapHandler {
            Button {
                onClose(.switchTool)
            } label: {
                logo
            }
            .buttonStyle(.plain)
            .disabled(state == .sending)
            .accessibilityLabel("Collie — switch tool")
        } else {
            logo
                .accessibilityLabel("Collie")
        }
    }

    /// The screenshot preview. Tapping it opens the markup editor — the tester can circle
    /// or scribble on the problem instead of describing where it is.
    private func previewSection(_ image: UIImage) -> some View {
        VStack(spacing: 6) {
            Button {
                focusedField = nil
                isMarkingUp = true
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(Color.accentColor))
                            .padding(8)
                    }
            }
            .buttonStyle(.plain)
            .disabled(state == .sending)
            .accessibilityLabel("Screenshot — tap to mark up")
            Text("Tap the screenshot to mark it up")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your name")
                .font(.headline)
            TextField("Enter your name (asked only once)", text: $testerName)
                .textFieldStyle(.roundedBorder)
                .disabled(state == .sending)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusNext() }
        }
    }

    private func fieldSection(
        title: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: text)
                    .frame(minHeight: 96)
                    .disabled(state == .sending)
                    .focused($focusedField, equals: field)
            }
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Could not send")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("This looks like a permanent error (configuration/permissions). If it persists, let the development team know.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var sendButton: some View {
        Group {
            if state == .sending {
                ProgressView()
            } else {
                Button("Send") { submit() }
                    .disabled(!canSend)
            }
        }
    }

    // MARK: - Submit

    private func submit() {
        guard canSend else { return }
        state = .sending
        let name = requiresName ? trimmedName : nil
        Task {
            let outcome = await BugReportComposer.send(
                whatHappened: trimmedHappened,
                testerName: name,
                screenshot: screenshot
            )
            await MainActor.run {
                switch outcome {
                case .sent(let reportID):
                    onClose(.sent(reportID: reportID))
                case .queued:
                    // Transient failure (e.g. no VPN): the report was queued to disk and
                    // will be retried automatically.
                    onClose(.queued)
                case .rejected(let message):
                    state = .failed(message)
                }
            }
        }
    }
}
#endif
