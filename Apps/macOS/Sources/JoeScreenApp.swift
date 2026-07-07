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
        _model = State(initialValue: AppModel(launchJoin: launchJoin))
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
    }
}
