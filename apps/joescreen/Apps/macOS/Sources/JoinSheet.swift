import SwiftUI
import JoeScreenKit

/// Direct Session Mode join sheet (§1): server URL + room + identity. Identity defaults to a fresh
/// UUID per launch (demo-critical: duplicate identities evict each other on LiveKit).
struct JoinSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL: String = "ws://localhost:7880"
    @State private var room: String = "demo"
    // Fresh identity per sheet presentation — never a shared default.
    @State private var identity: String = UUID().uuidString

    private var parsedURL: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespaces)) }
    private var canJoin: Bool {
        parsedURL != nil && !room.trimmingCharacters(in: .whitespaces).isEmpty
            && !identity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Join a Session")
                .font(.title2.bold())
            Text("Connect directly with a server URL, room name, and identity — no SharePlay needed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Server URL", text: $serverURL, prompt: Text("ws://localhost:7880"))
                    .textContentType(.URL)
                TextField("Room", text: $room, prompt: Text("demo"))
                HStack {
                    TextField("Identity", text: $identity)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        identity = UUID().uuidString
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Generate a fresh identity")
                }
            }
            .formStyle(.grouped)

            if parsedURL == nil && !serverURL.isEmpty {
                Label("That doesn't look like a valid URL.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Join") {
                    guard let url = parsedURL else { return }
                    model.requestJoin(DirectJoinParameters(
                        serverURL: url,
                        room: room.trimmingCharacters(in: .whitespaces),
                        identity: identity.trimmingCharacters(in: .whitespaces)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canJoin)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
