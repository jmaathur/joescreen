import SwiftUI
import JoeScreenKit
import JoeScreenUI
import JoeScreenLiveKit
import LiveKit

/// The in-call view: connection banner, roster, share controls. Remote shared windows are rendered
/// as separate native NSWindows (M4), not inside this view.
struct SessionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner()
            Divider()
            // The "see everyone" strip (M10): self tile + one per participant, between the banner
            // and the roster/shares split. Hidden until there's someone/something to show.
            ParticipantTileStrip()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                RosterView()
                    .frame(width: 220)
                Divider()
                SharesPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            // Bottom control bar: mic + camera split-buttons and Leave (CoScreen-style layout).
            MediaControlBar()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.beginShare()
                } label: {
                    Label("Share Window", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("Share one of your windows with the room")
            }
        }
    }
}

/// The media-plane connection state banner (distinct from the SharePlay/session state).
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    private var label: (String, Color) {
        switch model.mediaState {
        case .connected:    return ("Connected", .green)
        case .connecting:   return ("Connecting…", .yellow)
        case .reconnecting: return ("Reconnecting…", .orange)
        case .disconnected: return ("Disconnected", .secondary)
        case .failed(let r): return ("Failed: \(r)", .red)
        }
    }

    var body: some View {
        let (text, color) = label
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let p = model.joinParameters {
                Text("\(p.room)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// The list of windows currently shared in the room (owner-color labeled). M4 populates this from
/// the mirrored RoomModel and opens/moves the corresponding native windows.
struct SharesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shared = model.sharedWindowsSorted
        // The self camera preview now lives in the participant strip (M10), so the shares pane is
        // purely about shared windows: empty-state when there are none.
        if shared.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No windows shared yet")
                    .foregroundStyle(.secondary)
                Text("Click Share Window to share one of yours,\nor wait for someone else to share.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(shared, id: \.window) { entry in
                        SharedWindowTile(windowID: entry.window, ownerID: entry.owner)
                    }
                }
                .padding(12)
            }
        }
    }
}

/// A tile representing one shared window in the grid. Shows owner-color chrome, pause state, and a
/// state-aware action: **Focus** raises the native viewer window; **Reopen** re-subscribes a window
/// the user closed (M9). The placeholder glyph is the thumbnail until M10 upgrades it to live video.
struct SharedWindowTile: View {
    @Environment(AppModel.self) private var model
    let windowID: WindowID
    let ownerID: ParticipantID

    private var isClosed: Bool { model.isRemoteWindowClosed(windowID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(16.0/10.0, contentMode: .fit)
                .overlay {
                    // Live mini-thumbnail (M10): a SECOND SwiftUIVideoView on the already-held remote
                    // track (one decode, two renderers; the big window keeps its quality). Falls back
                    // to a glyph while the window is closed (no track) or not yet open.
                    if !isClosed, let track = model.remoteWindowTrack(windowID) {
                        SwiftUIVideoView(track, layoutMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: isClosed ? "macwindow.badge.plus" : "macwindow")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(model.color(for: ownerID), lineWidth: 3))
                .onTapGesture { focusOrReopen() }
            HStack(spacing: 6) {
                Circle().fill(model.color(for: ownerID)).frame(width: 8, height: 8)
                Text(model.shortLabel(for: ownerID))
                    .font(.caption.monospaced())
                if model.room.pauseState(of: windowID) == .paused {
                    Text("paused").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button(isClosed ? "Reopen" : "Focus") { focusOrReopen() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        }
    }

    private func focusOrReopen() {
        if isClosed { model.reopenRemoteWindow(windowID) }
        else { model.focusRemoteWindow(windowID) }
    }
}
