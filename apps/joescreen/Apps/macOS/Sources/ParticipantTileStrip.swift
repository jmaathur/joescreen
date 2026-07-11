import SwiftUI
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// The horizontal "see everyone" strip (M10): the self tile first (mirrored), then one tile per
/// remote participant, ordered by the pure `TileSubscriptionPlanner` (name-then-UUID, stable). Each
/// tile shows live camera video when there's a decodable camera track and the camera is on, else an
/// avatar (participant-color circle + initials). Off-screen tiles are detached by `LazyHStack`, so
/// adaptive-stream stops the SFU forwarding those cameras (R24/R32) — no manual unsubscribe needed.
struct ParticipantTileStrip: View {
    @Environment(AppModel.self) private var model

    private var tiles: [TileSubscriptionPlanner.Tile] { model.plannedTiles }

    var body: some View {
        if tiles.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(tiles, id: \.participant) { tile in
                        ParticipantTile(tile: tile)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 126)
            .background(.bar)
        }
    }
}

/// One 176×110 (16:10) participant tile.
private struct ParticipantTile: View {
    @Environment(AppModel.self) private var model
    let tile: TileSubscriptionPlanner.Tile

    private var media: ParticipantMediaState? { model.mediaState(for: tile.participant) }
    private var color: Color { model.color(for: tile.participant) }
    private var name: String { model.displayLabel(for: tile.participant) }
    private var micLive: Bool { tile.isSelf ? model.micEnabled : (media?.micLive ?? false) }
    private var isSpeaking: Bool { media?.isSpeaking ?? false }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                content
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                // Speaking ring (green) over the color ring.
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSpeaking ? Color.green : color, lineWidth: 3)
                // Mic-off badge, bottom-left.
                if !micLive {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "mic.slash.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.red, in: Circle())
                            Spacer()
                        }
                    }
                    .padding(5)
                }
            }
            .frame(width: 176, height: 110)
            Text(tile.isSelf ? "\(name) (you)" : name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: 176)
        }
        .onTapGesture {
            // Tapping a remote tile raises all that owner's shared windows.
            if !tile.isSelf { model.focusSharesOf(owner: tile.participant) }
        }
    }

    @ViewBuilder private var content: some View {
        if tile.isSelf {
            // Self: mirrored local camera preview when the camera is on, else avatar.
            if let track = model.localCameraTrack {
                SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .mirror)
            } else {
                AvatarView(name: name, color: color)
            }
        } else if tile.decoded, media?.cameraOn == true, let track = model.cameraTrack(for: tile.participant) {
            // Remote: live camera only when decodable (budget) AND camera-on (not a muted frozen frame).
            SwiftUIVideoView(track, layoutMode: .fill)
        } else {
            AvatarView(name: name, color: color)
        }
    }
}

/// The fallback tile face: a participant-color circle with up-to-two-letter initials.
private struct AvatarView: View {
    let name: String
    let color: Color

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.85)).frame(width: 52, height: 52)
            Text(initials)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}
