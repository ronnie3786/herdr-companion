enum HerdrHudTranscriptPresentation {
    /// Grouping keeps partial assistant prose with the tool/thinking activity.
    /// Terminal responses always return to the ordinary answer card, including
    /// failed and cancelled turns whose text may explain what happened.
    static func showsResponse(
        status: HeadlessAgentRunStatus,
        groupAllClankingActivity: Bool
    ) -> Bool {
        status.isTerminal || !groupAllClankingActivity
    }
}
