import Foundation
import os

/// Lightweight diagnostic logging for the app, visible via:
///   log stream --predicate 'subsystem == "com.joescreen.app"' --style compact
/// or the Console app. Used to observe the connect/capture/publish flow during the demo (there's no
/// interactive debugger in the automation loop).
public enum AppLog {
    private static let logger = Logger(subsystem: "com.joescreen.app", category: "app")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
