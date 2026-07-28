import Collie
import SwiftUI

/// Harness app: the smallest possible host for Collie's UI.
///
/// It exists because Collie's flow starts with a shake, and a shake cannot be triggered from
/// a script on the simulator — so the UI could only ever be verified by hand, in a real host
/// app. Here **Open report** calls `Collie.presentReport()` directly, which makes the banner,
/// the form and the markup editor reachable in one tap and drivable by a UI-automation tool.
///
/// The backend is deliberately unreachable (`example.invalid`): the remote kill switch fails
/// open and a send is queued, which is exactly the offline path a tester without VPN hits.
@main
struct CollieHarnessApp: App {

    init() {
        var config = CollieConfiguration(
            enabled: true,
            apiBaseURL: URL(string: "https://example.invalid")!,
            apiKey: "harness"
        )
        config.diagnostics = { print("[COLLIE]", $0) }
        Collie.configure(with: config)
    }

    var body: some Scene {
        WindowGroup { HarnessView() }
    }
}

struct HarnessView: View {

    @State private var secret = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Collie Harness")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Content to draw on in the markup editor")
                    .foregroundStyle(.white.opacity(0.9))
                // The screenshot is rendered with `drawHierarchy(afterScreenUpdates:)`, which
                // keeps secure fields masked — type here and check the capture.
                SecureField("Secure field (must be masked)", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
                Button("Open report") { Collie.presentReport() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
