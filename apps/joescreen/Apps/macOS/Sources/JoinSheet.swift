import AppKit
import SwiftUI
import JoeScreenKit

/// Direct Session Mode join sheet (§1): server URL + room + identity. Identity defaults to a fresh
/// UUID per launch (demo-critical: duplicate identities evict each other on LiveKit).
///
/// Layout follows the modern macOS idiom: a centered app-icon header over a grouped `Form`
/// (System Settings–style glass sections on macOS 26) with a capsule action bar at the bottom.
struct JoinSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    // Defaults to the production endpoint in Release, the local dev SFU in DEBUG (ServerConfig).
    @State private var serverURL: String = ServerConfig.defaultServerString
    @State private var room: String = "demo"
    // Fresh identity per sheet presentation — never a shared default.
    @State private var identity: String = UUID().uuidString
    // Display name (M10): defaults to the macOS full user name; peers see it on tiles + roster.
    @State private var displayName: String = NSFullUserName()
    // Join muted (backlog #2): defaults to the persisted preference.
    @State private var joinMuted: Bool = UserDefaults.standard.bool(forKey: "JoeScreen.joinMuted")
    @State private var showsAdvancedOptions = false

    private var parsedURL: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespaces)) }
    private var canJoin: Bool {
        parsedURL != nil && !room.trimmingCharacters(in: .whitespaces).isEmpty
            && !identity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 24)
                .padding(.bottom, 18)

            Form {
                Section("Profile") {
                    formFieldRow("Name", systemImage: "person.crop.circle") {
                        TextField("", text: $displayName, prompt: Text(NSFullUserName()))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            // One explicit content height across all text rows: a plain TextField's
                            // measured height can drift (e.g. while focused), unevening the rows.
                            .frame(height: 20)
                            .accessibilityLabel("Your name")
                    }
                }

                Section("Session") {
                    formFieldRow("Server", systemImage: "network") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            TextField("", text: $serverURL, prompt: Text(ServerConfig.defaultServerString))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(1)
                                .frame(height: 20)
                                .textContentType(.URL)
                                .accessibilityLabel("Server URL")
                            // Valid is the quiet default — only an invalid URL earns an indicator.
                            if !serverURL.isEmpty, parsedURL == nil {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(Color.orange)
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.caption)
                                    // Fixed square so the indicator never changes the row height.
                                    .frame(width: 16, height: 16)
                                    .help("Enter a valid server URL")
                            }
                        }
                    }

                    formFieldRow("Room", systemImage: "person.3") {
                        TextField("", text: $room, prompt: Text("demo"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .frame(height: 20)
                            .accessibilityLabel("Room")
                    }
                }

                Section {
                    Toggle(isOn: $joinMuted) {
                        HStack(alignment: .top, spacing: 10) {
                            rowIcon(joinMuted ? "mic.slash.fill" : "mic.fill",
                                    tint: joinMuted ? .red : .secondary)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Join muted")
                                Text("You can turn your microphone on after joining.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    // Match the switch's trailing edge to the native text-editor inset above.
                    .padding(.trailing, 5)
                }

                Section {
                    DisclosureGroup(isExpanded: $showsAdvancedOptions) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                TextField("Identity", text: $identity)
                                    .font(.body.monospaced())
                                Button {
                                    identity = UUID().uuidString
                                } label: {
                                    Label("Generate New Identity", systemImage: "arrow.clockwise")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("Generate a fresh identity")
                            }
                            Text("A unique identity lets multiple JoeScreen clients join the same room safely.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Advanced")
                            // Compensate for DisclosureGroup's chevron so this title lands on the
                            // same vertical guide as the other row titles.
                            .padding(.leading, 16)
                            .frame(minHeight: 20)
                    }
                }
            }
            .formStyle(.grouped)
            // The header already owns this spacing; remove Form's redundant first-section gutter.
            .contentMargins(.top, 0, for: .scrollContent)
            // Footer padding supplies the action-bar gap; retain only a small breathing margin.
            .contentMargins(.bottom, 4, for: .scrollContent)
            .scrollDisabled(true)
            // A grouped Form is scroll-view-backed, so it stretches to fill whatever height the
            // sheet offers, leaving dead space above the footer. Ideal height = content height.
            .fixedSize(horizontal: false, vertical: true)

            footer
        }
        .frame(width: 460)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            Text("Join JoeScreen")
                .font(.title2.bold())
            Text("Connect to a room and start collaborating.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// SF Symbols have different intrinsic widths. Reserving one icon column keeps every form
    /// label on the same vertical guide instead of letting wider symbols push text to the right.
    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            rowIcon(systemImage)
            Text(title)
        }
    }

    private func rowIcon(_ systemImage: String, tint: Color = .secondary) -> some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 18, alignment: .center)
    }

    /// A single baseline-aware row primitive keeps labels and editable values optically level.
    /// The fixed value column also makes every trailing edge identical while the sheet width is
    /// intentionally fixed.
    private func formFieldRow<Value: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            rowLabel(title, systemImage: systemImage)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            value()
                .frame(width: 250, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if parsedURL == nil && !serverURL.isEmpty {
                Label("Enter a valid server URL", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("Join Room") { join() }
                .keyboardShortcut(.defaultAction)
                .liquidGlassProminentButtonStyle()
                .controlSize(.large)
                .disabled(!canJoin)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func join() {
        guard let url = parsedURL else { return }
        model.joinMuted = joinMuted
        let name = displayName.trimmingCharacters(in: .whitespaces)
        model.requestJoin(DirectJoinParameters(
            serverURL: url,
            room: room.trimmingCharacters(in: .whitespaces),
            identity: identity.trimmingCharacters(in: .whitespaces),
            displayName: name.isEmpty ? nil : name))
        dismiss()
    }
}

private extension View {
    /// Liquid Glass prominent capsule on macOS 26 (the deployment floor stays macOS 14 per D2,
    /// so newer API is #available-gated here, never by raising the floor).
    @ViewBuilder
    func liquidGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
