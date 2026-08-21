#if canImport(UIKit)
import SwiftUI
import UIKit

/// One image the report is carrying: the picture itself, plus when it arrived and where
/// from — the two facts the analyst needs and the tester never types.
///
/// Identified rather than addressed by position: the tester can remove the second thumbnail
/// while the third is being marked up, and an index would then write the result onto the
/// wrong image.
struct BugReportShot: Identifiable {
    let id = UUID()
    var image: UIImage
    let event: CollieScreenshotEvent
}

/// Everything the tester has entered so far.
///
/// It lives outside the form because the form is **not** the only screen in this flow: the
/// tester leaves it for screenshot mode, walks through the app, and comes back. What they
/// had already written has to survive that trip — a bug reporter that loses the sentence
/// when you go and photograph the bug is one that gets used once.
struct BugReportDraft {
    var whatHappened: String = ""
    var testerName: String = ""
    var shots: [BugReportShot] = []
}

/// The bug report screen (SwiftUI). Presented from the banner's **Yes**.
///
/// The layout is the one a tester already knows from reporting a problem in a social app:
/// a title, the whole screen as one writing surface, and the evidence sitting on the
/// keyboard rather than competing with the text for room.
///
/// - **Title**: "What happened?" — so the field itself needs no label.
/// - Everything below is **one text field**, focused on open, with the keyboard already up.
///   Nothing else competes with it: the name, needed once per device, is asked in an alert
///   on the first **Send** — where there is room to say *why* it is being asked, which a
///   placeholder above the field never managed.
/// - Above the keyboard: the report's screenshots as thumbnails (each removable with ✕,
///   each tappable into the markup editor), and two buttons —
///   - **Screenshot** hands the app back to the tester so they can photograph other
///     screens (`ScreenshotModeOverlay`);
///   - **Upload** opens the system photo picker.
///   Both stop at `BugReportService.maxScreenshots`.
/// - **Send** → loading → report uploaded to the panel: closes with the report id on
///   success; on a transient failure the report is queued and the sheet closes with
///   "queued"; on a permanent failure an inline error is shown.
@MainActor
struct BugReportSheet: View {

    /// Why the sheet closed (the banner acts on it).
    enum Outcome {
        case cancelled
        case sent(reportID: String)
        case queued
        /// The logo in the navigation bar was tapped: close the Collie UI, then invoke
        /// the host's switch-tool handler.
        case switchTool
        /// The tester wants to photograph the app: hide the form — keeping everything in
        /// the draft — and enter screenshot mode.
        case captureScreenshots(draft: BugReportDraft)
    }

    enum SubmitState: Equatable {
        case idle
        case sending
        case failed(String)
    }

    /// Called when the sheet closes.
    let onClose: (_ outcome: Outcome) -> Void

    @State private var shots: [BugReportShot]
    @State private var whatHappened: String
    @State private var testerName: String
    @State private var state: SubmitState = .idle
    /// Non-nil while the markup editor is up, holding the image handed to it.
    @State private var markupSession: MarkupSession?
    /// Whether the system photo picker is up.
    @State private var isPickingScreenshots = false
    /// Whether the one-time name question is up. Raised by **Send**, not by opening the
    /// form: the tester came here to describe a bug, and being asked who they are before
    /// they have written a word is a question out of nowhere.
    @State private var isAskingName = false
    @FocusState private var isWriting: Bool

    /// Identified so SwiftUI can drive the cover from it. Carries the id of the shot being
    /// marked up, so the result lands on that image and no other.
    private struct MarkupSession: Identifiable {
        let id = UUID()
        let shotID: UUID
        let image: UIImage
    }

    init(draft: BugReportDraft, onClose: @escaping (_ outcome: Outcome) -> Void) {
        _shots = State(initialValue: draft.shots)
        _whatHappened = State(initialValue: draft.whatHappened)
        _testerName = State(initialValue: draft.testerName)
        self.onClose = onClose
    }

    /// What the form is holding right now — handed back when it steps aside for screenshot
    /// mode, and handed in again when it returns.
    private var draft: BugReportDraft {
        BugReportDraft(whatHappened: whatHappened, testerName: testerName, shots: shots)
    }

    /// How many images this report may carry. Read live rather than captured at init: the
    /// server-side value can land while the sheet is open, and the number shown next to the
    /// thumbnails must be the number the transport will honour.
    private var maxScreenshots: Int {
        Collie.bugReportService?.maxScreenshots ?? CollieConfiguration.maxScreenshotsLimit
    }

    private var room: Int { max(0, maxScreenshots - shots.count) }

    private let requiresName: Bool = !CollieDeviceIdentity.hasStoredName
    /// Whether the host registered a switch-tool handler (`Collie.onLogoTap`); when it
    /// did, the nav-bar logo becomes a button.
    private let hasLogoTapHandler: Bool = BugReportBanner.shared.logoTapHandler != nil

    private var trimmedHappened: String { whatHappened.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { testerName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The description is the only thing that gates the button. A missing name does not:
    /// it is asked for — and explained — after Send, and the flow carries straight on.
    private var canSend: Bool {
        !trimmedHappened.isEmpty && state != .sending
    }

    var body: some View {
        NavigationView {
            editor
                .navigationTitle("What happened?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { titleItem }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onClose(.cancelled) }
                            .disabled(state == .sending)
                    }
                    ToolbarItem(placement: .confirmationAction) { sendButton }
                }
                // The attachment bar rides the keyboard: `safeAreaInset` is laid out against
                // the keyboard's safe area, so it sits directly above it while typing and
                // falls to the bottom of the screen when the keyboard goes away. Anything
                // pinned to the bottom by hand ends up underneath the keyboard instead.
                .safeAreaInset(edge: .bottom, spacing: 0) { attachmentBar }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(state == .sending)
        .onAppear {
            // The tester came here to write a sentence; opening with the keyboard down
            // costs them a tap and hides the attachment bar, which lives above it.
            isWriting = true
        }
        .alert("One thing first", isPresented: $isAskingName) {
            TextField("Your name", text: $testerName)
                .textInputAutocapitalization(.words)
            Button("Save and send") { performSubmit() }
                .disabled(trimmedName.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Reports from every test device land in one list. Your name says which one "
                + "this came from — asked once, stored on this device."
            )
        }
        .fullScreenCover(item: $markupSession) { session in
            ScreenshotMarkupEditor(image: session.image) { marked in
                finishMarkup(session, with: marked)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isPickingScreenshots) {
            ScreenshotPicker(limit: room) { images in
                isPickingScreenshots = false
                attach(images)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Writing surface

    /// The whole screen is the field — nothing above it, nothing beside it.
    private var editor: some View {
        VStack(spacing: 0) {
            if case let .failed(message) = state {
                errorBanner(message)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            ZStack(alignment: .topLeading) {
                if whatHappened.isEmpty {
                    Text("Describe what happened, or what did not work.")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $whatHappened)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .disabled(state == .sending)
                    .focused($isWriting)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(.systemBackground))
        // Tapping the empty part of the page puts the cursor back in the field, the way a
        // full-page composer behaves everywhere else.
        .contentShape(Rectangle())
        .onTapGesture { isWriting = true }
    }

    // MARK: - Attachment bar

    /// The thumbnails and the two ways to add another, directly above the keyboard.
    @ViewBuilder
    private var attachmentBar: some View {
        if maxScreenshots > 0 {
            VStack(spacing: 10) {
                if !shots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shots) { shot in
                                thumbnail(shot)
                            }
                        }
                        // Room for the remove badge, which sits half outside the thumbnail.
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                    }
                }
                HStack(spacing: 10) {
                    attachmentButton(
                        title: "Screenshot",
                        systemImage: "camera",
                        action: {
                            isWriting = false
                            onClose(.captureScreenshots(draft: draft))
                        }
                    )
                    attachmentButton(
                        title: "Upload",
                        systemImage: "photo.on.rectangle",
                        action: {
                            isWriting = false
                            isPickingScreenshots = true
                        }
                    )
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func attachmentButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        // Both entries stop at the same place: past the limit the transport would drop the
        // image anyway, and offering it is a promise the report does not keep.
        .disabled(state == .sending || room == 0)
        .opacity(room == 0 ? 0.4 : 1)
    }

    private func thumbnail(_ shot: BugReportShot) -> some View {
        Button {
            startMarkup(shot)
        } label: {
            Image(uiImage: shot.image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                // `scaledToFill` leaves the image LARGER than the tile, and `clipShape` only
                // clips what is drawn — the touch area keeps the overflowing size. Two tiles
                // then overlap invisibly and the later one swallows its neighbour's remove
                // badge: tapping the ✕ opened the markup editor instead.
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(state == .sending)
        .accessibilityLabel("Screenshot — tap to mark it up")
        // An overlay rather than a child of the button above: a button inside a button is
        // one tap target, and removing an image would open the editor instead.
        .overlay(alignment: .topTrailing) {
            Button {
                remove(shot)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(state == .sending)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove screenshot")
        }
    }

    /// Small enough that a row of five fits above the keyboard without stealing the writing
    /// surface, large enough to tell two screens of the same app apart.
    private static let thumbnailWidth: CGFloat = 54
    private static let thumbnailHeight: CGFloat = 96

    // MARK: - Screenshots

    private func startMarkup(_ shot: BugReportShot) {
        isWriting = false
        markupSession = MarkupSession(shotID: shot.id, image: shot.image)
    }

    /// `nil` means the tester cancelled — the screenshot stays as it was.
    ///
    /// The result is written by id: if the tester removed that thumbnail while the editor
    /// was up, there is nothing to write it to and the marks are dropped with it, rather
    /// than landing on whichever image took its place.
    private func finishMarkup(_ session: MarkupSession, with marked: UIImage?) {
        if let marked, let index = shots.firstIndex(where: { $0.id == session.shotID }) {
            shots[index].image = marked
        }
        markupSession = nil
    }

    /// Appends picked images, never past the limit — the picker already caps the selection,
    /// and this holds even if a slower load lets a second selection through.
    private func attach(_ images: [UIImage]) {
        let now = Date()
        shots.append(
            contentsOf: images.prefix(room).map {
                BugReportShot(
                    image: $0,
                    // A library image was taken at some earlier, unknown time; what the
                    // stream can honestly record is when it was attached.
                    event: CollieScreenshotEvent(date: now, source: .library)
                )
            }
        )
    }

    private func remove(_ shot: BugReportShot) {
        shots.removeAll { $0.id == shot.id }
    }

    // MARK: - Sections

    /// The Collie logo in the navigation bar. When the host registered a switch-tool
    /// handler, it becomes a button: tapping it closes the Collie UI and hands off to
    /// the other tool (the handler runs after the UI has fully closed).
    @ViewBuilder
    private var titleItem: some View {
        HStack(spacing: 8) {
            let logo = Image(systemName: "pawprint.fill")
                .resizable()
                .scaledToFit()
                .frame(height: 18)
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
                logo.accessibilityLabel("Collie")
            }
            Text("What happened?")
                .font(.headline)
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
                    .font(.body.weight(.semibold))
                    .disabled(!canSend)
            }
        }
    }

    // MARK: - Submit

    /// Send, or — on this device's first report — ask who is filing it and then send.
    ///
    /// The question is raised here rather than on open, and it is an alert rather than a
    /// field, because it needs a paragraph of *why*: a name asked for with no reason given
    /// reads as data collection, and testers answer it with "a" and never look again.
    private func submit() {
        guard canSend else { return }
        isWriting = false
        guard !requiresName || !trimmedName.isEmpty else {
            isAskingName = true
            return
        }
        performSubmit()
    }

    private func performSubmit() {
        guard canSend else { return }
        state = .sending
        isWriting = false
        let name = requiresName ? trimmedName : nil
        let sent = shots
        Task {
            let outcome = await BugReportComposer.send(
                whatHappened: trimmedHappened,
                testerName: name,
                shots: sent
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
