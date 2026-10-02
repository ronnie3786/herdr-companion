import Foundation

enum SkimReplyAvailability {
    static func disabledReason(connected: Bool, busy: Bool, hasDraft: Bool) -> String? {
        if !connected { return "Reconnect to send a reply." }
        if busy { return "Wait for the current response to finish." }
        if hasDraft { return "Send or clear your draft before choosing a reply." }
        return nil
    }
}
