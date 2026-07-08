import SwiftUI
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// The bottom control bar of the in-call view (CoScreen-style): mic + camera split-buttons on the
/// left, a Leave button on the right. Each split-button is a primary toggle (click the icon to
/// mute/unmute or turn the camera on/off) plus a `⌄` menu to pick the input device — matching the
/// reference UI. Mic/camera state and device lists live on `AppModel`; this view is purely a
/// projection of that state.
struct MediaControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            // Microphone split-button: mic.fill when live, mic.slash.fill (red) when muted.
            MediaSplitButton(
                isOn: model.micEnabled,
                onSymbol: "mic.fill",
                offSymbol: "mic.slash.fill",
                onHelp: "Mute microphone",
                offHelp: "Turn on microphone",
                menuTitle: "Select your microphone",
                devices: model.audioInputs,
                selectedID: model.selectedAudioInputID,
                onToggle: { model.toggleMic() },
                onSelect: { model.selectAudioInput($0) },
                onMenuOpen: { Task { await model.refreshAudioInputs() } })

            // Camera split-button: video.fill when live, video.slash.fill (red) when off.
            MediaSplitButton(
                isOn: model.cameraEnabled,
                onSymbol: "video.fill",
                offSymbol: "video.slash.fill",
                onHelp: "Turn off camera",
                offHelp: "Turn on camera",
                menuTitle: "Select your camera",
                devices: model.videoInputs,
                selectedID: model.selectedVideoInputID,
                onToggle: { model.toggleCamera() },
                onSelect: { model.selectVideoInput($0) },
                onMenuOpen: { Task { await model.refreshVideoInputs() } })

            Spacer()

            Button(role: .destructive) {
                model.leave()
            } label: {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Leave the session")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// A two-part control: a toggle button (icon reflects on/off; red tint when off) fused with a `⌄`
/// menu that lists the selectable input devices. Generic over mic vs camera via its parameters.
private struct MediaSplitButton: View {
    let isOn: Bool
    let onSymbol: String
    let offSymbol: String
    let onHelp: String
    let offHelp: String
    let menuTitle: String
    let devices: [MediaInputDevice]
    let selectedID: String?
    let onToggle: () -> Void
    let onSelect: (String) -> Void
    let onMenuOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Primary toggle: click the icon to turn the device on/off.
            Button(action: onToggle) {
                Image(systemName: isOn ? onSymbol : offSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Color.primary : Color.red)
                    .frame(width: 34, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOn ? onHelp : offHelp)

            Divider().frame(height: 18)

            // Device-selection dropdown.
            Menu {
                Section(menuTitle) {
                    if devices.isEmpty {
                        Text("No devices found").foregroundStyle(.secondary)
                    }
                    ForEach(devices) { device in
                        Button {
                            onSelect(device.id)
                        } label: {
                            // A checkmark marks the active device; a device is "active" if it's the
                            // explicit selection, or (when nothing is chosen yet) the system default.
                            if isSelected(device) {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 28)
            .onTapGesture { onMenuOpen() } // refresh the list right before it renders
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    /// Whether `device` is the one currently in use: the explicit selection, or the system default
    /// when the user hasn't picked one yet.
    private func isSelected(_ device: MediaInputDevice) -> Bool {
        if let selectedID { return device.id == selectedID }
        return device.isDefault
    }
}

/// The local webcam self-preview tile (mirrored, like a normal selfie view). Rendered in the shares
/// area while the camera is on. Reuses LiveKit's `SwiftUIVideoView` — the same renderer as remote
/// windows (`RemoteVideoView`), which accepts a local `VideoTrack` directly.
struct SelfPreviewTile: View {
    @Environment(AppModel.self) private var model
    let track: VideoTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    SwiftUIVideoView(track, layoutMode: .fit, mirrorMode: .mirror)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: 3))
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                Text("You")
                    .font(.caption.monospaced())
                Spacer()
            }
        }
    }
}
