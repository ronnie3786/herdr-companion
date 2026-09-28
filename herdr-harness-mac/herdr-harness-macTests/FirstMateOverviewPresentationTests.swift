import Testing
@testable import herdr_harness_mac

struct FirstMateOverviewPresentationTests {
    @Test func explicitGoalWinsOverTicketBody() {
        let brief = """
        # SAMPLE-42: Ticket description
        Ticket: https://example.invalid/SAMPLE-42
        Background copied from the ticket.

        ## Goal
        Help people export receipts. Keep the exported totals accurate. A third implementation detail.

        ## Acceptance criteria
        - Inspect the database.
        - Add a button.
        """
        #expect(FirstMateGoalSummary.text(goal: brief, title: "Export receipts") == "Help people export receipts. Keep the exported totals accurate.")
    }

    @Test func legacyProseIsPlainAndShort() {
        #expect(FirstMateGoalSummary.text(goal: "Let people **find** their saved answers. Keep search fast. Use an index and add fixtures.", title: "Search") == "Let people find their saved answers. Keep search fast.")
        #expect(FirstMateGoalSummary.text(goal: "# Ticket\nTicket: https://example.invalid\n- An implementation checklist", title: "SAMPLE-42: Export receipts") == "Export receipts.")
    }

    @Test func friendlyModelLabelsOmitProviderRouting() {
        #expect(FirstMateUsageFormatting.modelName(provider: "openai-codex", model: "gpt-6-sol") == "GPT-6 Sol")
        #expect(FirstMateUsageFormatting.modelName(provider: "anthropic", model: "claude-sonnet-4-5") == "Claude Sonnet 4.5")
    }
}
