import Foundation
import Observation

/// In-memory, pane-scoped composer text. Drafts intentionally do not survive a
/// process restart and never become agent context before an explicit send.
@MainActor
@Observable
final class PaneDraftStore {
    private var drafts: [String: String] = [:]

    func text(for paneID: String) -> String {
        drafts[paneID] ?? ""
    }

    func setText(_ text: String, for paneID: String) {
        guard !paneID.isEmpty else { return }
        if text.isEmpty {
            guard drafts[paneID] != nil else { return }
            drafts[paneID] = nil
            return
        }
        guard drafts[paneID] != text else { return }
        drafts[paneID] = text
    }

    /// Clear only the exact submission that completed. A later edit in the
    /// same pane, or a draft in a newly selected pane, must remain untouched.
    @discardableResult
    func clearText(for paneID: String, ifUnchanged expectedText: String) -> Bool {
        guard drafts[paneID] == expectedText else { return false }
        drafts.removeValue(forKey: paneID)
        return true
    }

    /// A successful but empty machine response may be an incomplete poll. Do
    /// not discard user text until at least one valid pane establishes a real
    /// machine slice to reconcile against.
    func reconcile(machineID: String, validPaneIDs: Set<String>) {
        guard !validPaneIDs.isEmpty else { return }
        drafts = drafts.filter { paneID, _ in
            guard MachineScopedID.split(paneID)?.machineID == machineID else { return true }
            return validPaneIDs.contains(paneID)
        }
    }

    func removeAll(forMachineID machineID: String) {
        drafts = drafts.filter {
            MachineScopedID.split($0.key)?.machineID != machineID
        }
    }
}
