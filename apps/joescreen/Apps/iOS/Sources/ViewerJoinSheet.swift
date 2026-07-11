import SwiftUI
import JoeScreenKit

/// Direct Session Mode join sheet on iOS: server URL + room + identity (fresh UUID default).
struct ViewerJoinSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    // Defaults to the production endpoint in Release, the local dev SFU in DEBUG (ServerConfig).
    @State private var serverURL = ServerConfig.defaultServerString
    @State private var room = "demo"
    @State private var identity = UUID().uuidString
    // Display name (M10): defaults to the device name; peers see it on tiles + roster.
    @State private var displayName = UIDevice.current.name

    private var parsedURL: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespaces)) }
    private var canJoin: Bool {
        parsedURL != nil && !room.trimmingCharacters(in: .whitespaces).isEmpty
            && !identity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Your name", text: $displayName)
                }
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Room", text: $room)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Identity") {
                    HStack {
                        Text(identity).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { identity = UUID().uuidString } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
                Section {
                    Text("Share your voice and camera. iOS can't control other Macs' windows (it's a viewer for those).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Join a Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        guard let url = parsedURL else { return }
                        let name = displayName.trimmingCharacters(in: .whitespaces)
                        model.requestJoin(DirectJoinParameters(
                            serverURL: url,
                            room: room.trimmingCharacters(in: .whitespaces),
                            identity: identity.trimmingCharacters(in: .whitespaces),
                            displayName: name.isEmpty ? nil : name))
                        dismiss()
                    }
                    .disabled(!canJoin)
                }
            }
        }
    }
}
