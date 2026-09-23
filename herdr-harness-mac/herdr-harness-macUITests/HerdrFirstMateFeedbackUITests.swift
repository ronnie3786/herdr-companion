import XCTest

/// Synthetic end-to-end coverage for Mac First Mate response feedback. Every
/// response, reason, and rating comes from the built-in in-memory demo; no
/// companion server, operator database, or network connection participates.
final class HerdrFirstMateFeedbackUITests: HerdrUITestCase {
    @MainActor
    func testRatingReasonsCustomTextEditingAndRemoval() {
        let app = launchDemoApp()
        defer { app.terminate() }

        let firstMate = app.buttons["open-first-mate"]
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10), "The Chat navigator should list First Mate")
        firstMate.click()

        let up = app.control(identifier: "first-mate-feedback-up-\(Self.firstMessage)")
        let down = app.control(identifier: "first-mate-feedback-down-\(Self.firstMessage)")
        let status = app.control(identifier: "first-mate-feedback-status-\(Self.firstMessage)")
        XCTAssertTrue(up.waitForExistence(timeout: 10), "A completed response should offer thumbs up")
        XCTAssertTrue(down.exists, "A completed response should offer thumbs down")
        XCTAssertTrue(status.exists, "A completed response should show its rating state")
        XCTAssertFalse(
            app.control(identifier: "first-mate-feedback-up-\(Self.userMessage)").exists,
            "A user message must not offer response feedback"
        )

        // Thumbs up saves immediately and shows an explicit selected state.
        up.click()
        XCTAssertTrue(waitForLabel("Helpful", of: status))
        XCTAssertTrue(waitForLabel("Helpful response, selected", of: up))

        // Thumbs down opens the pinned editor with the three requested reasons,
        // initially unselected.
        down.click()
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-editor").waitForExistence(timeout: 5),
            "Thumbs down should open the feedback editor"
        )
        XCTAssertTrue(
            app.control(labelContaining: Self.responseFragment).exists,
            "The editor should be pinned to the exact response that was rated"
        )
        XCTAssertTrue(
            waitForLabelContaining(Self.responseFragment, in: app.control(identifier: "first-mate-feedback-context")),
            "The pinned response text should match the rated response"
        )
        for (id, label) in Self.defaultReasons {
            let row = app.control(identifier: "first-mate-feedback-category-\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "The editor should offer \(label)")
            XCTAssertTrue(waitForLabel(label, of: row), "The requested reason wording should stay exact")
            XCTAssertTrue(waitForValue("Not selected", of: row))
        }

        // Multiple reasons plus a multiline custom note.
        let tooLong = app.control(identifier: "first-mate-feedback-category-too_long")
        let unnecessary = app.control(identifier: "first-mate-feedback-category-unnecessary_message")
        let incorrect = app.control(identifier: "first-mate-feedback-category-incorrect_assumption")
        tooLong.click()
        XCTAssertTrue(waitForValue("Selected", of: tooLong))
        unnecessary.click()
        XCTAssertTrue(waitForValue("Selected", of: unnecessary))
        incorrect.click()
        XCTAssertTrue(waitForValue("Selected", of: incorrect))

        let comment = app.textViews["first-mate-feedback-comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5), "The editor should offer an optional note")
        comment.click()
        comment.typeText("Synthetic note line one")
        comment.typeKey(.return, modifierFlags: [])
        comment.typeText("line two")

        let save = app.control(identifier: "first-mate-feedback-save")
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "Saving should close the editor")
        XCTAssertTrue(waitForLabelContaining("3 reasons", in: status))
        XCTAssertTrue(waitForLabelContaining("note", in: status))
        XCTAssertTrue(waitForLabel("Not helpful response, selected", of: down))

        // Reopening is prefilled; Cancel leaves the saved rating unchanged.
        down.click()
        XCTAssertTrue(tooLong.waitForExistence(timeout: 5))
        for row in [tooLong, unnecessary, incorrect] {
            XCTAssertTrue(waitForValue("Selected", of: row))
        }
        XCTAssertTrue(waitForValueContaining("Synthetic note line one", of: comment))
        app.control(identifier: "first-mate-feedback-cancel").click()
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-editor").waitForNonExistence(timeout: 5),
            "Cancel should dismiss the editor"
        )
        XCTAssertTrue(waitForLabelContaining("3 reasons", in: status), "Cancel must not change the saved rating")

        // Editing removes one reason and keeps the note.
        down.click()
        XCTAssertTrue(tooLong.waitForExistence(timeout: 5))
        tooLong.click()
        XCTAssertTrue(waitForValue("Not selected", of: tooLong))
        app.control(identifier: "first-mate-feedback-save").click()
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-editor").waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(waitForLabelContaining("2 reasons", in: status))

        // Remove rating clears the active label only after the save succeeds.
        let remove = app.control(identifier: "first-mate-feedback-remove-\(Self.firstMessage)")
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "A saved rating should offer Remove rating")
        remove.click()
        XCTAssertTrue(waitForLabel("Rate this response", of: status))
        XCTAssertTrue(waitForLabel("Helpful response", of: up))
        XCTAssertTrue(waitForLabel("Not helpful response", of: down))
    }

    @MainActor
    func testCustomReusableReasonAcrossResponsesAndFeatures() {
        let app = launchDemoApp()
        defer { app.terminate() }

        let firstMate = app.buttons["open-first-mate"]
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10))
        firstMate.click()

        let firstDown = app.control(identifier: "first-mate-feedback-down-\(Self.firstMessage)")
        XCTAssertTrue(firstDown.waitForExistence(timeout: 10))
        firstDown.click()
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-editor").waitForExistence(timeout: 5)
        )

        // Add a reusable reason; it becomes selected for this response and
        // stays in the companion's catalog.
        let field = app.textFields["first-mate-feedback-add-category-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The editor should offer an Add reason field")
        field.click()
        field.typeText(Self.customReason)
        app.control(identifier: "first-mate-feedback-add-category").click()

        let custom = customCategoryRow(Self.customReason, in: app)
        XCTAssertTrue(custom.waitForExistence(timeout: 5), "Adding a reason should persist it in the catalog")
        XCTAssertTrue(waitForValue("Selected", of: custom), "A newly added reason should be selected")
        app.control(identifier: "first-mate-feedback-save").click()
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-editor").waitForNonExistence(timeout: 5)
        )
        let firstStatus = app.control(identifier: "first-mate-feedback-status-\(Self.firstMessage)")
        XCTAssertTrue(waitForLabelContaining("1 reason", in: firstStatus))

        // The second feature's response starts unrated and never exposes the
        // first feature's saved label.
        let secondFeature = app.buttons[Self.secondFeatureButton]
        XCTAssertTrue(secondFeature.waitForExistence(timeout: 5))
        secondFeature.click()
        let welcomeDown = app.control(identifier: "first-mate-feedback-down-\(Self.secondMessage)")
        XCTAssertTrue(welcomeDown.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-status-\(Self.firstMessage)").waitForNonExistence(timeout: 5),
            "Switching features must not retarget or leak another feature's feedback"
        )
        welcomeDown.click()
        let reused = customCategoryRow(Self.customReason, in: app)
        XCTAssertTrue(reused.waitForExistence(timeout: 5), "The added reason should remain available")
        let tooLong = app.control(identifier: "first-mate-feedback-category-too_long")
        XCTAssertTrue(waitForValue("Not selected", of: tooLong), "A different response should start unselected")
        reused.click()
        XCTAssertTrue(waitForValue("Selected", of: reused))
        app.control(identifier: "first-mate-feedback-save").click()
        XCTAssertTrue(reused.waitForNonExistence(timeout: 5))

        // Returning to the first feature restores only its own rating.
        app.buttons[Self.firstFeatureButton].click()
        XCTAssertTrue(waitForLabelContaining("1 reason", in: app.control(identifier: "first-mate-feedback-status-\(Self.firstMessage)")))
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-status-\(Self.secondMessage)").waitForNonExistence(timeout: 5)
        )
    }

    @MainActor
    func testCancelledCustomReasonStaysInCatalogWithoutResurrectingTheDraft() {
        let app = launchDemoApp()
        defer { app.terminate() }

        let firstMate = app.buttons["open-first-mate"]
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10))
        firstMate.click()

        let down = app.control(identifier: "first-mate-feedback-down-\(Self.firstMessage)")
        XCTAssertTrue(down.waitForExistence(timeout: 10))
        down.click()
        XCTAssertTrue(app.control(identifier: "first-mate-feedback-editor").waitForExistence(timeout: 5))

        // Add a reusable reason, then cancel the edit that had selected it.
        let field = app.textFields["first-mate-feedback-add-category-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(Self.cancelledReason)
        app.control(identifier: "first-mate-feedback-add-category").click()
        let custom = customCategoryRow(Self.cancelledReason, in: app)
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Selected", of: custom))
        app.control(identifier: "first-mate-feedback-cancel").click()
        XCTAssertTrue(
            app.control(identifier: "first-mate-feedback-editor").waitForNonExistence(timeout: 5),
            "Cancel should dismiss the editor"
        )

        // Reopening starts from the retained state: the confirmed reason is
        // still offered by the catalog, but the cancelled edit never
        // reselects it or restores the discarded draft.
        down.click()
        XCTAssertTrue(custom.waitForExistence(timeout: 5), "A confirmed reason stays in the companion's catalog")
        XCTAssertTrue(waitForValue("Not selected", of: custom), "Cancel must not resurrect the discarded draft")
        let status = app.control(identifier: "first-mate-feedback-status-\(Self.firstMessage)")
        XCTAssertTrue(waitForLabel("Rate this response", of: status))
        app.control(identifier: "first-mate-feedback-cancel").click()
    }

    // MARK: - Helpers

    @MainActor
    private func customCategoryRow(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label == %@",
                    "first-mate-feedback-category-",
                    label
                )
            )
            .firstMatch
    }

    @MainActor
    private func waitForLabel(
        _ label: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForLabelContaining(
        _ fragment: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", fragment, fragment),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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

    @MainActor
    private func waitForValueContaining(
        _ fragment: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", fragment),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let firstFeatureButton = "first-mate-feature-demo-demo-session-continuity"
    private static let secondFeatureButton = "first-mate-feature-demo-demo-search"
    private static let firstMessage = "demo-mate-0"
    private static let secondMessage = "demo-search-welcome"
    private static let userMessage = "demo-user-0"
    private static let responseFragment = "I traced the session boundary"
    private static let customReason = "Needs more evidence"
    private static let cancelledReason = "Cancelled reason"
    private static let defaultReasons = [
        ("too_long", "Longer than it needed to be"),
        ("unnecessary_message", "Unnecessary message"),
        ("incorrect_assumption", "Incorrect assumption"),
    ]
}
