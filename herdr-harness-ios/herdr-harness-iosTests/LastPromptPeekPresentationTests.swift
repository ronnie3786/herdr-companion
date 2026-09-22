import Testing
@testable import herdr_harness_ios

@Suite("Last prompt presentation")
struct LastPromptPeekPresentationTests {
    @Test("A menu prompt survives presentation, copies exact text, and dismisses")
    func presentCopyAndDismiss() {
        let message = PiUserMessage(
            id: "synthetic-last-prompt",
            text: "Summarize the synthetic navigation findings.",
            timestamp: nil
        )
        var presentation = LastPromptPeekPresentation()

        presentation.present(message)
        #expect(presentation.message == message)

        var copiedText: String?
        presentation.copy { copiedText = $0 }
        #expect(copiedText == message.text)

        presentation.dismiss()
        #expect(presentation.message == nil)
    }

    @Test("An unavailable prompt cannot replace or open presentation")
    func nilPromptDoesNotPresent() {
        var presentation = LastPromptPeekPresentation()

        presentation.present(nil)

        #expect(presentation.message == nil)
    }
}
