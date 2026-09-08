import Foundation
import Testing
@testable import herdr_harness_mac

struct SmartPaneTitleTests {
    @Test func validatesGeneratedTitles() {
        #expect(SmartPaneTitle.parse(#"{"title":"  Fix garden irrigation  "}"#) == "Fix garden irrigation")
        #expect(SmartPaneTitle.parse(#"{"title":" "}"#) == nil)
        #expect(SmartPaneTitle.parse(#"{"title":"First\nSecond"}"#) == nil)
        #expect(SmartPaneTitle.parse("Here is a good title") == nil)
        #expect(SmartPaneTitle.parse("{\"title\":\"\(String(repeating: "x", count: 81))\"}") == nil)
    }

    @Test func extractsConversationWithoutToolsOrReasoning() throws {
        let snapshot = try JSONDecoder().decode(PiConversationSnapshot.self, from: Data(#"""
        {"entries":[
          {"type":"message","id":"a","message":{"role":"user","content":[{"type":"text","text":"Fix garden irrigation"}]}},
          {"type":"message","id":"b","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Hidden reasoning"},{"type":"text","text":"Found a valve leak"},{"type":"toolCall","id":"t","name":"read","arguments":{"path":"private"}}]}}
        ]}
        """#.utf8))
        let context = SmartPaneTitle.context(from: snapshot)
        #expect(context.contains("Fix garden irrigation"))
        #expect(context.contains("Found a valve leak"))
        #expect(!context.contains("Hidden reasoning"))
        #expect(!context.contains("private"))
    }
}
