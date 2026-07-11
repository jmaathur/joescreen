import SwiftUI
import JoeScreenKit

/// The macOS app entry point. Owns the root scene and routes the three Direct Session Mode join
/// paths (IMPLEMENTATION_PROMPT §1) into the shared `AppModel`:
///   • launch arguments `--join-url … --room … --identity …` — parsed at construction so
///     `open -n JoeScreen.app --args --join-url …` joins with zero clicks (the demo path),
///   • `joescreen://join?…` deep links — handled via `.onOpenURL`,
///   • the join sheet — presented when no direct-join was requested.
@main
struct JoeScreenApp: App {
    @State private var model: AppModel

    init() {
        // Parse launch args once, before any UI. CommandLine.arguments[0] is the executable path.
        let args = Array(CommandLine.arguments.dropFirst())
        let launchJoin = DirectJoinParameters.fromLaunchArguments(args)
        // Optional --share-window-id <CGWindowID> to auto-share a window after joining (automation).
        let shareWindowID = JoeScreenApp.parseShareWindowID(args)
        _model = State(initialValue: AppModel(launchJoin: launchJoin, autoShareWindowID: shareWindowID))
    }

    /// Parse `--share-window-id <n>` (or `--share-window-id=<n>`) from the launch args.
    static func parseShareWindowID(_ args: [String]) -> UInt32? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--share-window-id", i + 1 < args.count { return UInt32(args[i + 1]) }
            if a.hasPrefix("--share-window-id=") {
                return UInt32(a.dropFirst("--share-window-id=".count))
            }
            i += 1
        }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    if let params = DirectJoinParameters.fromURL(url) {
                        model.requestJoin(params)
                    }
                }
                .task {
                    // If launched with --join-url, kick off the join as soon as the scene appears.
                    model.startLaunchJoinIfNeeded()
                }
        }
        // A single main window; remote shared windows are separate NSWindows (M4).
        .windowResizability(.contentSize)
        .commands {
            SharedWindowsCommands(model: model)
        }
    }
}

/// Window-menu commands for remote shared windows (M9): one Focus/Reopen item per share, plus
/// "Bring All Shared Windows to Front" and a "Follow new shares" toggle.
struct SharedWindowsCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            ForEach(model.sharedWindowsSorted, id: \.window) { entry in
                Button(sharedItemTitle(entry)) {
                    if model.isRemoteWindowClosed(entry.window) {
                        model.reopenRemoteWindow(entry.window)
                    } else {
                        model.focusRemoteWindow(entry.window)
                    }
                }
            }
            Button("Bring All Shared Windows to Front") {
                model.bringAllSharedWindowsToFront()
            }
            .disabled(model.sharedWindowsSorted.isEmpty)
            Toggle("Follow New Shares", isOn: Binding(
                get: { model.followNewShares },
                set: { model.setFollowNewShares($0) }))
        }
    }

    private func sharedItemTitle(_ entry: AppModel.SharedWindowEntry) -> String {
        let owner = model.shortLabel(for: entry.owner)
        let verb = model.isRemoteWindowClosed(entry.window) ? "Reopen" : "Focus"
        return "\(verb) Shared Window · \(owner)"
    }
}
