import Testing
@testable import herdr_harness_mac

@Suite("Agent board message attachments")
struct AgentBoardMessageContentTests {
    @Test("Uploaded file markers become named chips while surrounding text remains")
    func attachmentMarkers() {
        let value = AgentBoardMessageContent.parse("""
        Please inspect the diagram.

        Attachment: `/tmp/synthetic/flow diagram.png`
        Attachment: `first-mate:synthetic-feature/notes.txt`

        (transcribed audio, please account for incorrect names or typos)
        """)
        #expect(value.attachments.map(\.filename) == ["flow diagram.png", "notes.txt"])
        #expect(value.text.contains("Please inspect the diagram."))
        #expect(value.text.contains("(transcribed audio"))
        #expect(!value.text.contains("Attachment:"))
    }

    @Test("An attachment-only message has no empty prose or duplicate chips")
    func attachmentOnly() {
        let value = AgentBoardMessageContent.parse("Attachment: `/tmp/synthetic/report.pdf`\nAttachment: `/tmp/synthetic/report.pdf`")
        #expect(value.text.isEmpty)
        #expect(value.attachments.count == 1)
        #expect(value.attachments.first?.filename == "report.pdf")
    }

    @Test("Inline, quoted and fenced examples remain conversation text")
    func literalExamples() {
        let text = """
        Use Attachment: `/tmp/example` as an example.
        > Attachment: `/tmp/quoted`
            Attachment: `/tmp/indented`
        ```text
        Attachment: `/tmp/fenced`
        ```
        ~~~text
        Attachment: `/tmp/tilde-fenced`
        ~~~
        """
        let value = AgentBoardMessageContent.parse(text)
        #expect(value.text == text)
        #expect(value.attachments.isEmpty)
    }

    @Test("Malformed markers do not delete message text")
    func malformedMarkers() {
        let text = "Attachment: ``\nAttachment: `/tmp/synthetic` followed by prose\nAttachment: `/tmp/unclosed\nAttachment: `/tmp/inner`tick`"
        let value = AgentBoardMessageContent.parse(text)
        #expect(value.text == text)
        #expect(value.attachments.isEmpty)
    }
}
