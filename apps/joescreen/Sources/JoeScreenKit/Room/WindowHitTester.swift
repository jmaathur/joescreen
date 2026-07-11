import Foundation
import CoreGraphics

/// Pure hit-testing for the hover "Share" tab (CoScreen's signature gesture, backlog #10). Given a
/// global cursor point and a z-ordered snapshot of on-screen windows, decides WHICH window the tab
/// should attach to — the frontmost normal-layer window under the cursor that isn't ours and isn't a
/// desktop/menu/dock element. Pure so the z-order/pid/layer resolution is unit-tested without the
/// window server; the app feeds it a `CGWindowListCopyWindowInfo` snapshot mapped to `Candidate`s.
public enum WindowHitTester {

    /// One on-screen window from the CG window list (the fields hit-testing needs).
    public struct Candidate: Sendable, Equatable {
        public let cgWindowID: UInt32
        public let ownerPID: Int32
        /// CG window layer (0 = normal app windows; menu bar/dock/desktop are non-zero).
        public let layer: Int
        /// Global bounds (CG top-left origin).
        public let bounds: CGRect
        public let alpha: Double
        public init(cgWindowID: UInt32, ownerPID: Int32, layer: Int, bounds: CGRect, alpha: Double = 1) {
            self.cgWindowID = cgWindowID
            self.ownerPID = ownerPID
            self.layer = layer
            self.bounds = bounds
            self.alpha = alpha
        }
    }

    /// Resolve the window the hover tab should target.
    /// - Parameters:
    ///   - point: global cursor point (CG top-left).
    ///   - candidates: on-screen windows in FRONT-TO-BACK z-order (as CGWindowListCopyWindowInfo
    ///     returns with `.optionOnScreenOnly`). The FIRST match under the cursor wins (frontmost).
    ///   - ownPID: our own process id, excluded (never offer to share JoeScreen's own windows).
    /// - Returns: the target window's CGWindowID, or nil if the cursor isn't over a shareable window.
    public static func hit(point: CGPoint, candidates: [Candidate], ownPID: Int32) -> UInt32? {
        for c in candidates {
            guard c.ownerPID != ownPID else { continue }   // not our own windows
            guard c.layer == 0 else { continue }            // normal app windows only (skip menu/dock/desktop)
            guard c.alpha > 0.01 else { continue }          // skip fully-transparent windows
            guard c.bounds.width >= 40, c.bounds.height >= 40 else { continue } // skip tiny/util windows
            if c.bounds.contains(point) { return c.cgWindowID }
        }
        return nil
    }
}
