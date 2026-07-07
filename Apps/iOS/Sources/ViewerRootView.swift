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
            SharesTabView()
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
