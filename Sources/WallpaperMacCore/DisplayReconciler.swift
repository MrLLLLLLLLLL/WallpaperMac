import Foundation

public enum DisplayReconciliationAction: Equatable, Sendable {
    case keep
    case updateFrame
    case restore
    case disconnect
}

/// Pure per-display decision used by screen-change coordination. A change on
/// display B cannot force display A to rebuild when A's controller and current
/// item are still valid.
public enum DisplayReconciler {
    public static func action(
        isConnected: Bool,
        wasConnected: Bool,
        hasController: Bool,
        geometryChanged: Bool,
        currentItemMatches: Bool,
        expectedItemAvailable: Bool
    ) -> DisplayReconciliationAction {
        guard isConnected else { return .disconnect }
        guard wasConnected, hasController, currentItemMatches, expectedItemAvailable else {
            return .restore
        }
        return geometryChanged ? .updateFrame : .keep
    }
}
