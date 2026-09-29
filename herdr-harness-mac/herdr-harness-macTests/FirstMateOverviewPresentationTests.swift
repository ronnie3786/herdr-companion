import Testing
@testable import herdr_harness_mac

struct FirstMateOverviewPresentationTests {
    @Test func friendlyModelLabelsOmitProviderRouting() {
        #expect(FirstMateUsageFormatting.modelName(provider: "openai-codex", model: "gpt-6-sol") == "GPT-6 Sol")
        #expect(FirstMateUsageFormatting.modelName(provider: "anthropic", model: "claude-sonnet-4-5") == "Claude Sonnet 4.5")
    }
}
