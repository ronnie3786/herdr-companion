import Foundation

enum AgentBoardSessionRoute {
    /// Session identifiers are only meaningful within their companion host.
    /// A same-named session on another Mac must never capture this navigation.
    static func livePane(nativeSessionID: String, machineID: String, panes: [HerdrPane]) -> HerdrPane? {
        guard !nativeSessionID.isEmpty else { return nil }
        return panes.first {
            $0.machineID == machineID && $0.supportsPiSemanticChat
                && $0.piSemantic?.connected == true && $0.piSemantic?.sessionID == nativeSessionID
        }
    }
}
