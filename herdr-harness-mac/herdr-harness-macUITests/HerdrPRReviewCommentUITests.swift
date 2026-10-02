import AppKit
import XCTest

/// Acceptance coverage for host-local Human/Agent discussions using the explicit
/// synthetic demo client. Demo discussions last for the app process; durable
/// storage and relaunch behavior belong to companion service tests. The unique
/// previous-comment store below keeps legacy operator data out of these tests.
final class HerdrPRReviewCommentUITests: HerdrUITestCase {
    private var storeDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-pr-review-comments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeDirectory = directory
    }

    override func tearDownWithError() throws {
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        storeDirectory = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testSelectedCodeSavesMultilineDiscussionWithLocationAndCopy() {
        let app = launchDemoApp(commentStoreURL: temporaryCommentStoreDirectory())
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))

        let body = "First line with **Markdown**\nSecond line stays exact"
        saveSelectionComment(in: main, app: app, body: body)
        let comments = openCommentsList(in: main, app: app)
        assertCommentBody(body, in: comments)
        let thread = threadCard(containing: body, in: comments)
        XCTAssertTrue(thread.waitForExistence(timeout: 5), "The saved comment should have its own thread")
        XCTAssertTrue(thread.discussionText(containing: SyntheticPRReview.firstPath).exists)
        XCTAssertTrue(thread.discussionText(containing: "before ").exists, "A mixed selection retains the removed side")
        XCTAssertTrue(thread.discussionText(containing: "after ").exists, "A mixed selection retains the added side")
        XCTAssertTrue(thread.descendantButton(titled: "Show in diff").exists)
        expandDisclosure("Original code", in: thread)
        XCTAssertTrue(thread.discussionText(containing: "struct SeedCatalog {}").waitForExistence(timeout: 5),
                      "The original selected code should remain available")

        let copy = thread.descendantButton(titled: "Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        XCTAssertTrue(waitForPasteboard("Human:\n" + body), "Copy preserves attribution and exact saved Markdown")
    }

    @MainActor
    func testHumanRepliesToAgentAndResolvesReopensWithOriginalCodeAndActivity() {
        let app = launchDemoApp(commentStoreURL: temporaryCommentStoreDirectory())
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))
        let comments = openCommentsList(in: main, app: app)
        let thread = comments.descendant(identifier: "pr-review-thread-demo-catalog-thread")
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        XCTAssertTrue(thread.discussionText(containing: "Swift reviewer: How will an empty catalog").exists)
        XCTAssertTrue(thread.discussionText(containing: "Agent").exists)
        let reply = thread.descendant(identifier: "pr-review-thread-reply-demo-catalog-thread")
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.click()
        let body = "Human review: please add an explicit loading state.\nThe empty case needs a test."
        saveDraft(body, in: app)
        assertCommentBody(body, in: thread)
        XCTAssertTrue(thread.discussionText(containing: "Human").exists)

        let state = thread.descendant(identifier: "pr-review-thread-state-demo-catalog-thread")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        state.click()
        XCTAssertTrue(thread.waitForNonExistence(timeout: 5), "Resolved threads leave the Open filter")
        selectCommentFilter("Resolved", in: comments)
        XCTAssertTrue(thread.descendantButton(titled: "Reopen").waitForExistence(timeout: 5))
        thread.descendantButton(titled: "Reopen").click()
        XCTAssertTrue(thread.waitForNonExistence(timeout: 5), "Reopened threads leave the Resolved filter")
        selectCommentFilter("All", in: comments)
        XCTAssertTrue(thread.descendantButton(titled: "Resolve").waitForExistence(timeout: 5))
        expandDisclosure("Original code", in: thread)
        XCTAssertTrue(thread.discussionText(containing: "+struct SeedCatalog {}").waitForExistence(timeout: 5))
        expandDisclosure("Activity (", in: thread)
        XCTAssertTrue(thread.discussionText(containing: "Human replied").waitForExistence(timeout: 5))
        XCTAssertTrue(thread.discussionText(containing: "Human resolved").exists)
        XCTAssertTrue(thread.discussionText(containing: "Human reopened").exists)
    }

    @MainActor
    func testShowInDiffClearsFiltersAndRestoresSavedLocation() {
        let app = launchDemoApp(commentStoreURL: temporaryCommentStoreDirectory())
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))
        let search = main.textFields["Filter files"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("no-synthetic-file-matches-this-filter")
        XCTAssertTrue(main.descendant(identifier: "pr-review-no-filter-matches").waitForExistence(timeout: 5))
        selectTab("Context", expectedContentIdentifier: "pr-review-context", in: main)

        let comments = openCommentsList(in: main, app: app)
        let thread = comments.descendant(identifier: "pr-review-thread-demo-catalog-thread")
        let show = thread.descendantButton(titled: "Show in diff")
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.click()
        XCTAssertTrue(app.control(identifier: "pr-review-discussions").waitForNonExistence(timeout: 5))
        XCTAssertTrue(main.descendant(identifier: "pr-review-file-0").waitForExistence(timeout: 10))
        XCTAssertFalse(main.descendant(identifier: "pr-review-no-filter-matches").exists)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))
        let savedPath = main.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", SyntheticPRReview.firstPath, SyntheticPRReview.firstPath)
        ).firstMatch
        XCTAssertTrue(savedPath.waitForExistence(timeout: 10))
    }

    @MainActor
    func testPRLevelCommentAndRepliesAreSharedAcrossWindowsAndIsolatedByReview() {
        let app = launchDemoApp(commentStoreURL: temporaryCommentStoreDirectory())
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))
        let original = "Question about the overall sync approach.\nThis applies to the full PR."
        let comments = openCommentsList(in: main, app: app)
        comments.descendant(identifier: "pr-review-add-pr-comment").click()
        saveDraft(original, in: app)
        let created = threadCard(containing: original, in: comments)
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertTrue(created.discussionText(containing: "Pull request").exists)
        XCTAssertFalse(created.descendantButton(titled: "Show in diff").exists)
        closeCommentsList(in: app)

        let row = main.buttons[SyntheticPRReview.rowIdentifier(SyntheticPRReview.firstReviewID)]
        bringForward(row, in: app)
        choosePopOut(SyntheticPRReview.firstReviewID, from: row, in: app)
        let popout = waitForReviewWindow(SyntheticPRReview.firstReviewID, in: app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: popout))
        let popoutComments = openCommentsList(in: popout, app: app, windowTitle: SyntheticPRReview.firstTitle)
        assertCommentBody(original, in: popoutComments)
        let shared = threadCard(containing: original, in: popoutComments)
        shared.descendantButton(titled: "Reply").click()
        let reply = "Follow-up from the pop-out review window."
        saveDraft(reply, in: app)
        assertCommentBody(reply, in: shared)
        closeCommentsList(in: app)

        let mainComments = openCommentsList(in: main, app: app)
        assertCommentBody(original, in: mainComments)
        assertCommentBody(reply, in: mainComments)
        closeCommentsList(in: app)
        selectReview(SyntheticPRReview.secondReviewID, in: main, app: app, expectedDiff: SyntheticPRReview.secondDiff)
        let secondComments = openCommentsList(in: main, app: app)
        XCTAssertTrue(secondComments.discussionText(containing: "No open comments").waitForExistence(timeout: 5))
        XCTAssertFalse(secondComments.discussionText(containing: "Question about the overall sync approach").exists)
        secondComments.descendant(identifier: "pr-review-add-pr-comment").click()
        saveDraft("Reminder-only synthetic comment", in: app)
        closeCommentsList(in: app)

        selectReview(SyntheticPRReview.firstReviewID, in: main, app: app, expectedDiff: SyntheticPRReview.firstDiff)
        let restored = openCommentsList(in: main, app: app)
        assertCommentBody(original, in: restored)
        assertCommentBody(reply, in: restored)
        XCTAssertFalse(restored.discussionText(containing: "Reminder-only synthetic comment").exists)
    }

    // MARK: - Shared steps

    /// The unique per-test store directory created in `setUpWithError`.
    private func temporaryCommentStoreDirectory(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL {
        guard let storeDirectory else {
            XCTFail("The temporary comment store directory should exist", file: file, line: line)
            return FileManager.default.temporaryDirectory
        }
        return storeDirectory
    }

    /// Opens the review rail and returns the main shell window once both
    /// synthetic reviews and the first review's file list are addressable.
    @MainActor
    private func openPRReview(_ app: XCUIApplication) -> XCUIElement {
        let open = app.control(identifier: "open-pr-review")
        XCTAssertTrue(open.waitForExistence(timeout: 10), "The navigator should expose PR Review")
        open.click()

        let firstRow = app.buttons[SyntheticPRReview.rowIdentifier(SyntheticPRReview.firstReviewID)]
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 10),
            "Demo mode should list the first synthetic active review"
        )
        XCTAssertTrue(
            app.buttons[SyntheticPRReview.rowIdentifier(SyntheticPRReview.secondReviewID)].waitForExistence(timeout: 5),
            "Demo mode should list both synthetic active reviews"
        )

        let window = app.windows.containing(.any, identifier: "nav-history-controls").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The main shell window should stay addressable")
        XCTAssertTrue(
            window.descendant(identifier: "pr-review-file-0").waitForExistence(timeout: 10),
            "The selected review should publish its changed files"
        )
        return window
    }

    /// Waits until the bundled WebKit renderer has published this diff text.
    /// Selecting before the first paint yields no selection and no Add comment.
    @MainActor
    private func waitForDiffText(_ fragment: String, in window: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let diff = window.webViews.firstMatch
        guard diff.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let rendered = diff.staticTexts.allElementsBoundByIndex.map {
                ($0.value as? String) ?? $0.label
            }.joined()
            if rendered.contains(fragment) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    /// Selects every rendered diff line and activates the real DOM
    /// **Add comment** control, then waits for the native editor.
    @MainActor
    private func selectAllAndAddComment(in window: XCUIElement, app: XCUIApplication) {
        let diff = window.webViews.firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 10), "The review window should mount the shared diff")
        diff.click()
        app.typeKey("a", modifierFlags: .command)

        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@", "Add comment", "Add comment")
        let candidates = {
            [
                diff.buttons.matching(predicate).firstMatch,
                diff.descendants(matching: .any).matching(predicate).firstMatch,
                app.buttons.matching(predicate).firstMatch,
            ]
        }
        var button = waitForFirst(of: candidates(), timeout: 3)
        if button == nil {
            // A lost first selection is recoverable; never fall back to
            // injecting a comment message without a real selection.
            diff.click()
            app.typeKey("a", modifierFlags: .command)
            button = waitForFirst(of: candidates(), timeout: 7)
        }
        guard let button else {
            XCTFail("Selecting diff code should offer Add comment; tree: \(diff.debugDescription)")
            return
        }
        // A coordinate click lands on the DOM control even when WebKit
        // publishes its text node rather than the button itself.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(
            app.control(identifier: "pr-review-discussion-body").waitForExistence(timeout: 10),
            "Add comment should open the local comment editor"
        )
    }

    @MainActor
    private func typeCommentBody(
        _ body: String,
        in app: XCUIApplication,
        clearing: Bool = false
    ) -> XCUIElement? {
        guard let field = waitForFirst(of: [
            app.textViews["pr-review-discussion-body"],
            app.control(identifier: "pr-review-discussion-body"),
        ], timeout: 10) else { return nil }
        field.click()
        // A replacement selects the prefilled edit text first so the result is
        // exactly what was typed, independent of caret position.
        if clearing { app.typeKey("a", modifierFlags: .command) }
        for (index, segment) in body.components(separatedBy: "\n").enumerated() {
            if index > 0 { app.typeKey(.return, modifierFlags: []) }
            if !segment.isEmpty { field.typeText(segment) }
        }
        return field
    }

    @MainActor
    private func saveSelectionComment(in window: XCUIElement, app: XCUIApplication, body: String) {
        selectAllAndAddComment(in: window, app: app)
        saveDraft(body, in: app)
        closeCommentsList(in: app)
    }

    @MainActor
    private func saveDraft(_ body: String, in app: XCUIApplication) {
        guard let field = typeCommentBody(body, in: app) else {
            XCTFail("The discussion composer should expose its multiline body")
            return
        }
        XCTAssertEqual(field.value as? String, body, "The composer keeps the exact typed text")
        let save = app.control(identifier: "pr-review-discussion-save")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        waitUntilEnabled(save)
        save.click()
        XCTAssertTrue(app.control(identifier: "pr-review-discussion-body").waitForNonExistence(timeout: 5),
                      "A successful save should clear the composer")
    }

    @MainActor
    private func openCommentsList(
        in window: XCUIElement,
        app: XCUIApplication,
        windowTitle: String = "Herdr Companion"
    ) -> XCUIElement {
        bringForward(window, in: app, windowTitle: windowTitle)
        let button = window.descendant(identifier: "pr-review-comments-button")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The review header should expose Comments")
        waitUntilEnabled(button)
        button.click()

        // AppKit can reparent the sheet's accessibility tree after its opening
        // animation. Keep the query rooted at the app, not the presenting window.
        let sheet = app.control(identifier: "pr-review-discussions")
        if !sheet.waitForExistence(timeout: 5) {
            // A first click can land while the window is still activating.
            button.click()
        }
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The Comments control should open the review-wide list")
        return sheet
    }

    @MainActor
    private func closeCommentsList(in app: XCUIApplication) {
        let done = waitForFirst(of: [
            app.control(identifier: "pr-review-discussions").descendantButton(titled: "Done"),
            app.buttons["Done"],
        ], timeout: 5)
        XCTAssertNotNil(done)
        done?.click()
        XCTAssertTrue(
            app.control(identifier: "pr-review-discussions").waitForNonExistence(timeout: 5),
            "Done should close the review-wide comments list"
        )
    }

    @MainActor
    private func assertCommentBody(
        _ body: String,
        in sheet: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for fragment in body.components(separatedBy: "\n") where !fragment.isEmpty {
            XCTAssertTrue(sheet.discussionText(containing: fragment).waitForExistence(timeout: 10),
                          "Expected saved text: \(fragment)", file: file, line: line)
        }
    }

    @MainActor
    private func threadCard(containing body: String, in sheet: XCUIElement) -> XCUIElement {
        let fragment = body.components(separatedBy: "\n")[0]
        let cards = sheet.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pr-review-thread-"))
        let deadline = Date().addingTimeInterval(5)
        repeat {
            for identifier in cards.allElementsBoundByIndex.map(\.identifier) {
                let card = sheet.groups.matching(identifier: identifier).firstMatch
                if card.discussionText(containing: fragment).exists { return card }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTFail("The discussion should retain the saved message: \(fragment)")
        return sheet.groups["missing-discussion-thread"]
    }

    @MainActor
    private func expandDisclosure(_ titlePrefix: String, in scope: XCUIElement) {
        let label = NSPredicate(format: "label BEGINSWITH %@ OR title BEGINSWITH %@", titlePrefix, titlePrefix)
        guard let disclosure = waitForFirst(of: [
            scope.disclosureTriangles.matching(label).firstMatch,
            scope.buttons.matching(label).firstMatch,
            scope.descendants(matching: .any).matching(label).firstMatch,
        ], timeout: 5) else {
            XCTFail("The thread should expose \(titlePrefix)")
            return
        }
        // AppKit includes a leading inset in the disclosure's AX frame. The
        // visible arrow sits 28 points in, before the noninteractive label.
        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 28, dy: 0)).click()
    }

    @MainActor
    private func selectCommentFilter(_ title: String, in sheet: XCUIElement) {
        guard let segment = waitForFirst(of: [sheet.radioButtons[title], sheet.buttons[title]], timeout: 5) else {
            XCTFail("The discussion status picker should offer \(title)")
            return
        }
        segment.click()
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isEnabled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(element.isEnabled, "The control should become enabled")
    }

    @MainActor
    private func waitForPasteboard(_ expected: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if NSPasteboard.general.string(forType: .string) == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func selectTab(
        _ title: String,
        expectedContentIdentifier: String,
        in window: XCUIElement
    ) {
        let picker = window.descendant(identifier: "pr-review-mode-picker")
        guard picker.waitForExistence(timeout: 10) else {
            XCTFail("The review should expose its tab picker")
            return
        }
        let prefix = NSPredicate(format: "label BEGINSWITH[c] %@", title)
        guard let segment = waitForFirst(of: [
            picker.buttons[title],
            picker.radioButtons[title],
            picker.descendants(matching: .any).matching(prefix).firstMatch,
        ], timeout: 5) else {
            XCTFail("The tab picker should offer \(title)")
            return
        }
        segment.click()
        XCTAssertTrue(
            window.descendant(identifier: expectedContentIdentifier).waitForExistence(timeout: 10),
            "The \(title) tab content should mount"
        )
    }

    @MainActor
    private func selectReview(
        _ reviewID: String,
        in window: XCUIElement,
        app: XCUIApplication,
        expectedDiff: String
    ) {
        let row = window.buttons[SyntheticPRReview.rowIdentifier(reviewID)]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        bringForward(row, in: app)
        row.click()
        XCTAssertTrue(
            waitForDiffText(expectedDiff, in: window),
            "Review \(reviewID) should render its own diff"
        )
    }

    // MARK: - Pop-out windows

    @MainActor
    private func choosePopOut(_ reviewID: String, from anchor: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(anchor.waitForExistence(timeout: 10), "The context-menu anchor should exist")
        anchor.rightClick()

        let identifier = SyntheticPRReview.popOutIdentifier(reviewID)
        guard let item = waitForFirst(
            of: [
                app.menuItems[identifier],
                app.menuItems["Pop Out into Window"],
                app.control(identifier: identifier),
            ],
            timeout: 5
        ) else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Right-clicking should offer Pop Out into Window")
            return
        }
        item.click()
    }

    @MainActor
    private func reviewWindows(in app: XCUIApplication, reviewID: String) -> [XCUIElement] {
        let identifier = SyntheticPRReview.windowIdentifier(reviewID)
        return app.windows.containing(.any, identifier: identifier).allElementsBoundByIndex
    }

    @MainActor
    private func waitForReviewWindow(
        _ reviewID: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = reviewWindows(in: app, reviewID: reviewID).first { return window }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline

        XCTFail("A review window for \(reviewID) should open")
        return app.windows.firstMatch
    }

    /// Choose the exact window through the native Window menu. Hittability
    /// alone does not reliably detect overlap, and keyboard cycling depends on
    /// the user's configured shortcut and window order.
    @MainActor
    private func bringForward(_ anchor: XCUIElement, in app: XCUIApplication, windowTitle: String = "Herdr Companion") {
        XCTAssertTrue(anchor.exists)
        app.activate()
        let windowMenu = app.menuBars.menuBarItems["Window"]
        windowMenu.click()
        let item = windowMenu.menuItems.matching(
            NSPredicate(format: "title == %@ OR label == %@", windowTitle, windowTitle)
        ).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Window menu must offer \(windowTitle)")
        // Use the visible menu row directly. XCUI's menu-item click routine
        // can re-hover a stale item after AppKit has already dismissed the menu.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}

/// The synthetic reviews `PRReviewDemo` publishes, named only through their
/// stable identifiers and rendered text. UI tests never import the app module.
private enum SyntheticPRReview {
    static let firstReviewID = "prr_demo42"
    static let secondReviewID = "prr_demo43"
    static let firstTitle = "Add seed catalog sync"
    static let firstDiff = "struct SeedCatalog {}"
    static let firstPath = "Sources/Catalog/SeedCatalog.swift"
    static let secondDiff = "struct ReminderSchedule {}"

    static func rowIdentifier(_ reviewID: String) -> String {
        "pr-review-review-\(reviewID)"
    }

    static func windowIdentifier(_ reviewID: String) -> String {
        "pr-review-window-demo|\(reviewID)"
    }

    static func popOutIdentifier(_ reviewID: String) -> String {
        "pr-review-pop-out-demo|\(reviewID)"
    }
}

private extension XCUIElement {
    /// Discussion prose is exposed as StaticText. Restrict AXValue queries to
    /// text so AppKit does not evaluate it recursively on container controls.
    func discussionText(containing fragment: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", fragment, fragment)).firstMatch
    }
}
