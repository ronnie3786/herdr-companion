import SwiftUI

/// Shared execution facts for the feature window, lead window, and lead HUD.
/// A continuing conversation does not by itself prove that work is running.
struct FirstMateExecutionStateNotice: View {
    let snapshot: FirstMateSnapshot
    let health: FirstMateRuntimeHealth?

    var body: some View {
        if let text = Self.message(snapshot: snapshot, health: health) {
            FirstMateExecutionNotice(text: text, lastSuccessAt: health?.warning == nil ? nil : health?.lastSuccessAt)
        }
    }

    static func message(snapshot: FirstMateSnapshot, health: FirstMateRuntimeHealth?) -> String? {
        guard !["completed", "cancelled"].contains(snapshot.feature.status) else { return nil }
        if let warning = health?.warning { return warning }
        if snapshot.feature.status == "blocked" {
            return snapshot.events.last(where: { $0.type == "reliability.blocked" })?.summary
                ?? "Work is blocked. Review the retained evidence and give First Mate direction."
        }
        if snapshot.recoveryNeedsDirection {
            return health?.automaticRecovery == true
                ? "Checking retained work for a safe automatic continuation. First Mate will ask if a human decision is needed."
                : "Execution was interrupted. Inspect the retained work before asking First Mate to recover."
        }
        return nil
    }
}
