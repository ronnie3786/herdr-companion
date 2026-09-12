import Testing
@testable import herdr_harness_ios

@Suite("Composer code block paste")
struct ComposerCodeBlockPasteTests {
    @Test("Fences preserve clipboard whitespace and nested backticks")
    func fencesLiteralText() {
        #expect(ComposerCodeBlockPaste.fenced("  let value = 1\n") == "```\n  let value = 1\n```")
        #expect(
            ComposerCodeBlockPaste.fenced("```swift\nvalue\n```")
                == "````\n```swift\nvalue\n```\n````"
        )
    }

    @Test("Paste appends without normalizing the existing draft")
    func preservesDraftWhitespace() {
        let draft = "\n  Keep this indentation  "
        #expect(
            ComposerCodeBlockPaste.appending("code", to: draft)
                == draft + "\n```\ncode\n```"
        )
        #expect(
            ComposerCodeBlockPaste.appending("code", to: "existing\n")
                == "existing\n```\ncode\n```"
        )
    }
}
