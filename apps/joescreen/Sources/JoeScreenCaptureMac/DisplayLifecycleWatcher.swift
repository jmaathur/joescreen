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
/// itself. `@unchecked Sendable`: immutable config + ALL mutable state guarded by `lock`. `start()`,
/// `stop()`, and the timer handler are called from different executors (the DisplayCaptureService
/// actor, the utility timer queue, and — for the notification observers — an arbitrary thread), so
/// every mutable field is mutated only under `lock`, and `stop()` is idempotent.
final class DisplayLifecycleWatcher: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let onLockChange: @Sendable (Bool) -> Void
    private let onDisplayRemoved: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.joescreen.capture.display", qos: .utility)
    private let lock = NSLock()
    // All guarded by `lock`.
    private var timer: DispatchSourceTimer?
    private var removedFired = false
    private var stopped = false
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
        let lockObs = dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.onLockChange(true)
        }
        let unlockObs = dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.onLockChange(false)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0) // 1 Hz
        timer.setEventHandler { [weak self] in self?.pollDisplayPresence() }

        lock.lock()
        // A stop() that raced ahead of start() → don't arm anything.
        guard !stopped else {
            lock.unlock()
            dnc.removeObserver(lockObs); dnc.removeObserver(unlockObs); timer.cancel()
            return
        }
        self.lockObserver = lockObs
        self.unlockObserver = unlockObs
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return } // idempotent
        stopped = true
        let t = timer; let lockObs = lockObserver; let unlockObs = unlockObserver
        timer = nil; lockObserver = nil; unlockObserver = nil
        lock.unlock()
        t?.cancel()
        let dnc = DistributedNotificationCenter.default()
        if let lockObs { dnc.removeObserver(lockObs) }
        if let unlockObs { dnc.removeObserver(unlockObs) }
    }

    private func pollDisplayPresence() {
        lock.lock()
        let alreadyDone = removedFired || stopped
        lock.unlock()
        guard !alreadyDone else { return }
        guard !Self.activeDisplayIDs().contains(displayID) else { return }
        lock.lock()
        // Re-check under lock; fire the terminal callback at most once.
        guard !removedFired, !stopped else { lock.unlock(); return }
        removedFired = true
        lock.unlock()
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
