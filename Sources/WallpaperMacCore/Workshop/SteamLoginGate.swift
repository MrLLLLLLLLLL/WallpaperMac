import Foundation

/// Pure decision for the Workshop browse login gate. Kept out of SwiftUI so
/// the "no re-prompt loop / cancel closes browse" rules are unit-testable.
public enum SteamLoginGate: Equatable, Sendable {
    case showLogin
    case continueBrowsing
    case closeBrowse

    /// - Parameters:
    ///   - isLoggedIn: session marker / SteamCMD cache present.
    ///   - sheetDismissed: the login sheet's onDismiss just ran.
    ///   - loginSucceeded: onLoggedIn fired for this presentation.
    ///   - loginCancelled: onCancelled / ✕ / cancel fired for this presentation.
    public static func decide(
        isLoggedIn: Bool,
        sheetDismissed: Bool,
        loginSucceeded: Bool,
        loginCancelled: Bool
    ) -> SteamLoginGate {
        if !sheetDismissed {
            return isLoggedIn ? .continueBrowsing : .showLogin
        }
        // Sheet just closed: explicit outcomes win; swipe-dismiss without an
        // outcome falls back to current login state (never re-show the sheet).
        if loginCancelled { return .closeBrowse }
        if loginSucceeded || isLoggedIn { return .continueBrowsing }
        return .closeBrowse
    }
}
