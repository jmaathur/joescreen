import SwiftUI
import AppKit
import JoeScreenKit

/// The root content view. Shows the join sheet when idle, the in-call session view otherwise.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
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
        // Keep one stable minimum across idle, connecting, and in-call phases. Compact enough to
        // tuck beside other work: sidebar + a usable center column + the 220pt face inspector.
        .frame(minWidth: 880, minHeight: 520)
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
        // The session toolbar is useful once the call exists, but an empty title/toolbar strip makes
        // this transient state look like an unfinished window. Extend the loading surface behind the
        // traffic lights and restore the normal window chrome as soon as this view disappears.
        .background(CleanLoadingWindowChrome())
    }
}

/// Temporarily removes the empty macOS title/toolbar strip without changing the in-call window.
/// The traffic-light controls remain available over the full-size loading surface.
private struct CleanLoadingWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> CleanLoadingWindowChromeView {
        CleanLoadingWindowChromeView()
    }

    func updateNSView(_ nsView: CleanLoadingWindowChromeView, context: Context) {
        nsView.applyIfPossible()
    }

    static func dismantleNSView(_ nsView: CleanLoadingWindowChromeView, coordinator: ()) {
        nsView.restore()
    }
}

@MainActor
private final class CleanLoadingWindowChromeView: NSView {
    private struct PreviousChrome {
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarAppearsTransparent: Bool
        let usedFullSizeContentView: Bool
        let toolbarWasVisible: Bool?
    }

    private weak var configuredWindow: NSWindow?
    private var previousChrome: PreviousChrome?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfPossible()
    }

    func applyIfPossible() {
        guard let window else { return }
        if configuredWindow !== window {
            restore()
            configuredWindow = window
            previousChrome = PreviousChrome(
                titleVisibility: window.titleVisibility,
                titlebarAppearsTransparent: window.titlebarAppearsTransparent,
                usedFullSizeContentView: window.styleMask.contains(.fullSizeContentView),
                toolbarWasVisible: window.toolbar?.isVisible)
        }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar?.isVisible = false
    }

    func restore() {
        guard let configuredWindow, let previousChrome else { return }
        configuredWindow.titleVisibility = previousChrome.titleVisibility
        configuredWindow.titlebarAppearsTransparent = previousChrome.titlebarAppearsTransparent
        if previousChrome.usedFullSizeContentView {
            configuredWindow.styleMask.insert(.fullSizeContentView)
        } else {
            configuredWindow.styleMask.remove(.fullSizeContentView)
        }
        if let toolbarWasVisible = previousChrome.toolbarWasVisible {
            configuredWindow.toolbar?.isVisible = toolbarWasVisible
        }
        self.configuredWindow = nil
        self.previousChrome = nil
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
