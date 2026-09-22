import XCTest

/// Synthetic coverage that First Mate hosts the same prompt composer contract
/// as Chat without inheriting pane-only terminal or Pi-maintenance controls.
final class HerdrFirstMateChatParityUITests: HerdrUITestCase {
    @MainActor
    func testSharedComposerSubmissionAndFeatureScopedDrafts() {
        let app = launchDemoApp()
        defer { app.terminate() }

        let firstMate = app.buttons["open-first-mate"]
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10), "The Chat navigator should list First Mate")
        firstMate.click()

        var editor = app.textViews["composer-draft-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "First Mate should expose the shared draft editor")
        XCTAssertTrue(
            app.control(identifier: "first-mate-copy-demo-mate-0").waitForExistence(timeout: 5),
            "The deterministic demo response should retain its copy affordance"
        )

        for (identifier, name) in [
            ("composer-attach-file", "Attach"),
            ("composer-code-block-paste", "Paste code"),
            ("composer-record-voice", "Voice"),
            ("composer-more-tools", "More"),
            ("prompt-send", "Send"),
        ] {
            XCTAssertTrue(
                app.control(identifier: identifier).waitForExistence(timeout: 5),
                "First Mate should expose the shared \(name) affordance"
            )
        }

        XCTAssertFalse(app.control(identifier: "composer-terminal-keys-toggle").exists)
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal-key-"))
                .count,
            0,
            "First Mate should not expose pane terminal keys"
        )

        let more = app.control(identifier: "composer-more-tools")
        more.click()
        XCTAssertTrue(
            app.text(containing: "Prompt tools").waitForExistence(timeout: 5),
            "The shared More popover should open"
        )
        XCTAssertFalse(app.control(identifier: "composer-compact-pi-chat").exists)
        XCTAssertFalse(app.control(identifier: "composer-reload-pi-session").exists)
        app.typeKey(.escape, modifierFlags: [])

        editor = app.textViews["composer-draft-editor"]
        editor.click()
        editor.typeText("Shift line")
        editor.typeKey(.return, modifierFlags: .shift)
        editor.typeText("Option line")
        editor.typeKey(.return, modifierFlags: .option)
        editor.typeText("Command line")
        editor.typeKey(.return, modifierFlags: .command)
        editor.typeText("Final line")
        XCTAssertTrue(
            waitForValue(Self.firstDraft, of: editor),
            "Every modified Return should add a line without sending"
        )
        XCTAssertFalse(
            exactTranscriptText(Self.firstDraft, in: app).exists,
            "Modified Return must leave the exact draft unsent"
        )

        let secondFeature = app.buttons["first-mate-feature-demo-demo-search"]
        XCTAssertTrue(secondFeature.waitForExistence(timeout: 5), "The demo should expose a second stable feature")
        secondFeature.click()
        editor = app.textViews["composer-draft-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("", of: editor), "A different feature should start with its own draft")
        editor.click()
        editor.typeText(Self.secondDraft)
        XCTAssertTrue(waitForValue(Self.secondDraft, of: editor))

        let firstFeature = app.buttons["first-mate-feature-demo-demo-session-continuity"]
        XCTAssertTrue(firstFeature.waitForExistence(timeout: 5))
        firstFeature.click()
        editor = app.textViews["composer-draft-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue(Self.firstDraft, of: editor),
            "Returning to the first feature should restore only its draft"
        )

        editor.click()
        editor.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("", of: editor, timeout: 10), "Plain Return should send and clear the editor")
        XCTAssertTrue(
            exactTranscriptText(Self.firstDraft, in: app).waitForExistence(timeout: 10),
            "The transcript should contain the exact synthetic multiline message"
        )

        secondFeature.click()
        editor = app.textViews["composer-draft-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue(Self.secondDraft, of: editor),
            "Sending from one feature must not consume another feature's draft"
        )
    }

    @MainActor
    private func exactTranscriptText(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier != %@ AND (label == %@ OR value == %@)",
                    "composer-draft-editor",
                    text,
                    text
                )
            )
            .firstMatch
    }

    @MainActor
    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let firstDraft = "Shift line\nOption line\nCommand line\nFinal line"
    private static let secondDraft = "Independent search feature draft"
}
