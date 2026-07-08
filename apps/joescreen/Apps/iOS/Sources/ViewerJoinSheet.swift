import SwiftUI
import JoeScreenKit

/// Direct Session Mode join sheet on iOS: server URL + room + identity (fresh UUID default).
struct ViewerJoinSheet: View {
    @Environment(ViewerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = "ws://localhost:7880"
    @State private var room = "demo"
    @State private var identity = UUID().uuidString

    private var parsedURL: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespaces)) }
    private var canJoin: Bool {
        parsedURL != nil && !room.trimmingCharacters(in: .whitespaces).isEmpty
            && !identity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("iOS is a viewer + voice client. It cannot control or share windows.")
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
                        model.requestJoin(DirectJoinParameters(
                            serverURL: url,
                            room: room.trimmingCharacters(in: .whitespaces),
                            identity: identity.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(!canJoin)
                }
            }
        }
    }
}
