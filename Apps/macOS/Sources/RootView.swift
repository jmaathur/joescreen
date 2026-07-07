import SwiftUI
import JoeScreenKit

/// The root content view. Shows the join sheet when idle, the in-call session view otherwise.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .idle:
                WelcomeView()
            case .connecting:
                ConnectingView()
            case .inCall:
                SessionView()
            case .failed(let message):
                FailureView(message: message)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .sheet(isPresented: $model.showJoinSheet) {
            JoinSheet()
        }
    }
}

/// Idle landing: title + a button to open the join sheet.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("JoeScreen")
                .font(.largeTitle.bold())
            Text("Shared desktops over a live call.")
                .foregroundStyle(.secondary)
            Button("Join a Session…") { model.showJoinSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}

/// Shown while dialing the SFU.
struct ConnectingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(.title3)
            if let p = model.joinParameters {
                Text("\(p.room) · \(p.serverURL.absoluteString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { model.leave() }
                .controlSize(.regular)
        }
        .padding(40)
    }
}

/// Terminal-failure surface with a retry-into-sheet affordance.
struct FailureView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Couldn't join")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { model.showJoinSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}
