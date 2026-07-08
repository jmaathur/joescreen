import SwiftUI
import JoeScreenKit

/// The iOS app entry point (M8). VIEWER + VOICE ONLY — iOS cannot be remote-controlled and cannot
/// inject input into other apps (R6, permanent), so there is deliberately no control/share surface.
/// Direct Session Mode join works exactly as on macOS (URL scheme + join sheet; launch args aren't a
/// thing on iOS but the deep link is).
@main
struct JoeScreeniOSApp: App {
    @State private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            ViewerRootView()
                .environment(model)
                .onOpenURL { url in
                    if let params = DirectJoinParameters.fromURL(url) {
                        model.requestJoin(params)
                    }
                }
                .task {
                    // DEBUG-only: auto-join from env so the simulator can be driven WITHOUT the
                    // iOS custom-URL-scheme confirmation dialog (which automation can't tap). Set via
                    // `simctl launch --terminate-running-process <sim> com.joescreen.app.ios` with
                    // JOESCREEN_JOIN_URL/ROOM/IDENTITY in the environment.
                    #if DEBUG
                    let env = ProcessInfo.processInfo.environment
                    if let urlString = env["JOESCREEN_JOIN_URL"], let url = URL(string: urlString) {
                        let room = env["JOESCREEN_ROOM"] ?? "demo"
                        let identity = env["JOESCREEN_IDENTITY"] ?? UUID().uuidString
                        model.requestJoin(DirectJoinParameters(serverURL: url, room: room, identity: identity))
                    }
                    #endif
                }
        }
    }
}
