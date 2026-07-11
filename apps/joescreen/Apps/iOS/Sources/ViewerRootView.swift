import SwiftUI
import JoeScreenKit
import JoeScreenLiveKit
import LiveKit

/// The iOS viewer's root view (M8): join sheet → tabbed/zoomable remote shared windows + roster.
struct ViewerRootView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            content
                .navigationTitle("JoeScreen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.phase == .inCall {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Leave") { model.leave() }
                        }
                    }
                }
        }
        .sheet(isPresented: $model.showJoinSheet) { ViewerJoinSheet() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            ViewerWelcome()
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .inCall:
            InCallView()
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn't join").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Try Again") { model.showJoinSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ViewerWelcome: View {
    @Environment(ViewerModel.self) private var model
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 48)).foregroundStyle(.tint)
            Text("JoeScreen").font(.largeTitle.bold())
            Text("Watch a shared session. Viewer + voice.")
                .foregroundStyle(.secondary)
            Button("Join a Session…") { model.showJoinSheet = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }.padding()
    }
}

/// The in-call layout: the remote shares fill the screen, a mirrored camera self-preview floats in a
/// corner (only while the camera is on), and a control bar at the bottom toggles mic + camera.
struct InCallView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            SharesTabView()
            // Self-preview PiP (mirrored) while the camera is on.
            if let track = model.localCameraTrack {
                VStack {
                    HStack {
                        Spacer()
                        SelfPreviewPiP(track: track)
                            .padding(.top, 8).padding(.trailing, 12)
                    }
                    Spacer()
                }
            }
            iOSMediaControlBar()
        }
    }
}

/// The bottom control bar: mic + camera toggles (+ flip camera), mirroring the desktop control bar.
struct iOSMediaControlBar: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        HStack(spacing: 22) {
            controlButton(on: model.micEnabled,
                          onSymbol: "mic.fill", offSymbol: "mic.slash.fill") { model.toggleMic() }
            controlButton(on: model.cameraEnabled,
                          onSymbol: "video.fill", offSymbol: "video.slash.fill") { model.toggleCamera() }
            if model.cameraEnabled {
                controlButton(on: true, onSymbol: "arrow.triangle.2.circlepath.camera", offSymbol: "arrow.triangle.2.circlepath.camera") {
                    model.flipCamera()
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 8)
    }

    private func controlButton(on: Bool, onSymbol: String, offSymbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(on ? Color.primary : Color.red)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The mirrored camera self-preview picture-in-picture.
struct SelfPreviewPiP: View {
    let track: VideoTrack
    var body: some View {
        SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .mirror)
            .frame(width: 96, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.6), lineWidth: 2))
            .shadow(radius: 4)
    }
}

/// The remote shared windows as a swipeable, zoomable tab view. `SwiftUIVideoView` has pinch-zoom
/// built in on iOS.
struct SharesTabView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        let tracks = model.sortedTracks
        if tracks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.dashed").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("No windows shared yet").foregroundStyle(.secondary)
            }
        } else {
            TabView {
                ForEach(tracks, id: \.window) { entry in
                    ZoomableVideoPane(window: entry.window, track: entry.track)
                        .tabItem { Label("Window", systemImage: "macwindow") }
                }
            }
            .tabViewStyle(.page)
        }
    }
}

/// One remote shared window: the live, pinch-zoomable video with the owner-color border.
struct ZoomableVideoPane: View {
    @Environment(ViewerModel.self) private var model
    let window: WindowID
    let track: RemoteVideoTrackRef

    var body: some View {
        ZStack {
            Color.black
            // SwiftUIVideoView on iOS has pinch-zoom / pan built in.
            SwiftUIVideoView(track, layoutMode: .fit, pinchToZoomOptions: [.zoomIn, .zoomOut, .resetOnRelease])
        }
        .overlay(
            Rectangle().strokeBorder(model.color(for: model.owner(of: window)), lineWidth: 3))
        .ignoresSafeArea(edges: .bottom)
    }
}
