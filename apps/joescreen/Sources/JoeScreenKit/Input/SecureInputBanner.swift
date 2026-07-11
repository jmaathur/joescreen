import Foundation

/// The pure decision for the Secure Event Input banner (spec R8), in JoeScreenKit so it is unit-
/// tested by the machine gate. The macOS probe (`IsSecureEventInputEnabled`) lives in
/// `JoeScreenInputMac.SecureInputDetector`, which feeds this decision the live flag.
///
/// When any app enables secure input (a focused password field, some terminals), the window server
/// BLOCKS synthesized events from other processes — a remote driver's injection silently does
/// nothing. Rather than look broken, the app shows a "this field can't be remote-controlled" banner
/// while secure input is active AND someone is driving.
public enum SecureInputBanner: Sendable, Equatable {
    case none
    /// Secure input is blocking injection — show the R8 notice.
    case secureInputBlocking

    /// Decide the banner: shown only when secure input is active AND a remote peer is driving.
    public static func decide(secureInputActive: Bool, someoneIsDriving: Bool) -> SecureInputBanner {
        (secureInputActive && someoneIsDriving) ? .secureInputBlocking : .none
    }
}
