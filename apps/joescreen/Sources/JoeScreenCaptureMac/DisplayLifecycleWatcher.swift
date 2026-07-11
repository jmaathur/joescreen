import Foundation

#if os(macOS)
import CoreGraphics

/// Watches a shared display's lifecycle (spec §M11):
///  • **Screen lock/unlock** via `DistributedNotificationCenter` (`com.apple.screenIsLocked` /
///    `com.apple.screenIsUnlocked`) → pause/resume. SCK keeps delivering LOCK-SCREEN frames while
///    locked, so `PauseDetector` alone would never fire — this is the explicit signal.
///  • **Display removal** (unplugged / turned off) via a 1 Hz `CGGetActiveDisplayList` poll → the
///    display is no longer active → terminal unshare (fires once).
///
/// Callbacks may fire on the distributed-notification thread or the poll queue; the actor hops onto
/// itself. `@unchecked Sendable`: immutable config + a lock-guarded fired flag.
final class DisplayLifecycleWatcher: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let onLockChange: @Sendable (Bool) -> Void
    private let onDisplayRemoved: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.joescreen.capture.display", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var removedFired = false
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

    init(displayID: CGDirectDisplayID,
         onLockChange: @escaping @Sendable (Bool) -> Void,
         onDisplayRemoved: @escaping @Sendable () -> Void) {
        self.displayID = displayID
        self.onLockChange = onLockChange
        self.onDisplayRemoved = onDisplayRemoved
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        lockObserver = dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.onLockChange(true)
        }
        unlockObserver = dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.onLockChange(false)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0) // 1 Hz
        timer.setEventHandler { [weak self] in self?.pollDisplayPresence() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        let dnc = DistributedNotificationCenter.default()
        if let lockObserver { dnc.removeObserver(lockObserver) }
        if let unlockObserver { dnc.removeObserver(unlockObserver) }
        lockObserver = nil
        unlockObserver = nil
    }

    private func pollDisplayPresence() {
        guard !removedFired else { return }
        guard !Self.activeDisplayIDs().contains(displayID) else { return }
        removedFired = true
        onDisplayRemoved()
        stop()
    }

    /// The currently-active display IDs.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

#endif
