import SwiftUI
import JoeScreenKit

/// The macOS app entry point. Owns the root scene and routes the three Direct Session Mode join
/// paths (IMPLEMENTATION_PROMPT §1) into the shared `AppModel`:
///   • launch arguments `--join-url … --room … --identity …` — parsed at construction so
///     `open -n JoeScreen.app --args --join-url …` joins with zero clicks (the demo path),
///   • `joescreen://join?…` deep links — handled via `.onOpenURL`,
///   • the join sheet — presented when no direct-join was requested.
/// Keeps the app resident when all windows close (backlog #5) so the menu-bar item stays alive.
final class JoeScreenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct JoeScreenApp: App {
    @NSApplicationDelegateAdaptor(JoeScreenAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // Parse launch args once, before any UI. CommandLine.arguments[0] is the executable path.
        let args = Array(CommandLine.arguments.dropFirst())
        let launchJoin = DirectJoinParameters.fromLaunchArguments(args)
        // Optional --share-window-id <CGWindowID> to auto-share a window after joining (automation).
        let shareWindowID = JoeScreenApp.parseShareWindowID(args)
        // Optional --share-display-id <CGDirectDisplayID> / --share-main-display to auto-share a screen.
        let shareDisplayID = JoeScreenApp.parseShareDisplayID(args)
        _model = State(initialValue: AppModel(
            launchJoin: launchJoin, autoShareWindowID: shareWindowID, autoShareDisplayID: shareDisplayID))
    }

    /// Parse `--share-window-id <n>` (or `--share-window-id=<n>`) from the launch args.
    static func parseShareWindowID(_ args: [String]) -> UInt32? {
        parseUInt32Flag(args, flag: "--share-window-id")
    }

    /// Parse `--share-display-id <n>` / `--share-display-id=<n>`, or `--share-main-display`
    /// (resolves to the main display ID) from the launch args.
    static func parseShareDisplayID(_ args: [String]) -> CGDirectDisplayID? {
        if args.contains("--share-main-display") { return CGMainDisplayID() }
        return parseUInt32Flag(args, flag: "--share-display-id")
    }

    private static func parseUInt32Flag(_ args: [String], flag: String) -> UInt32? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == flag, i + 1 < args.count { return UInt32(args[i + 1]) }
            if a.hasPrefix("\(flag)=") { return UInt32(a.dropFirst(flag.count + 1)) }
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

        // Menu-bar residency (backlog #5): quick controls + Recent list even with no window open.
        MenuBarExtra("JoeScreen", systemImage: "person.2.wave.2.fill") {
            JoeScreenMenu(model: model)
        }
    }
}

/// The menu-bar menu (backlog #5): mic toggle, share, copy invite link, recents, leave. Teardown
/// (leave) still runs from here so a menu-bar-only session can be ended cleanly.
struct JoeScreenMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.phase == .inCall {
            Button(model.micEnabled ? "Mute Mic" : "Unmute Mic") { model.toggleMic() }
            Button("Share…") { model.beginShare() }
            if let invite = model.inviteURL {
                Button("Copy Invite Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(invite.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Leave Session") { model.leave() }
        } else {
            Text("Not in a session").foregroundStyle(.secondary)
            if !model.recents.entries.isEmpty {
                Divider()
                Menu("Recent") {
                    ForEach(model.recents.entries, id: \.key) { entry in
                        Button(recentLabel(entry)) { model.joinRecent(entry) }
                    }
                }
            }
        }
        Divider()
        Button("Quit JoeScreen") { NSApplication.shared.terminate(nil) }
    }

    private func recentLabel(_ entry: RecentsStore.Entry) -> String {
        let host = URL(string: entry.serverURL)?.host ?? entry.serverURL
        return "\(entry.room) · \(host)"
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
