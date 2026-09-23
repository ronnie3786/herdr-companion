import AppKit
import XCTest

/// Interactive acceptance coverage for local PR Review comments.
///
/// Every test launches the synthetic `-HerdrDemoMode` fleet with a unique
/// temporary comment store handed to the DEBUG-only
/// `-HerdrPRReviewCommentStorePath` argument, so records are written to an
/// isolated file and a real termination/relaunch can prove persistence without
/// touching the operator's data. The tests drive the actual bundled diff
/// renderer for selection, keep the existing PR Review suites untouched, and
/// never open a browser or submit anything to GitHub: Copy uses only the system
/// pasteboard, and Open file in GitHub is asserted to exist, never clicked.
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

    // MARK: - Save, preview, copy

    @MainActor
    func testSelectedCodeSavesMultilineCommentWithPreviewAndCopy() {
        let app = launchDemoApp(commentStoreURL: temporaryCommentStoreDirectory())
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(
            waitForDiffText(SyntheticPRReview.firstDiff, in: main),
            "The synthetic diff should render before selecting code"
        )

        let body = "First line with **Markdown**\nSecond line stays exact"
        saveSelectionComment(in: main, app: app, body: body)

        let comments = openCommentsList(in: main, app: app)
        assertCommentBody(body, in: comments)

        let preview = commentElement(prefix: "pr-review-comment-preview-", in: comments)
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Each comment should show its saved code excerpt")
        XCTAssertTrue(
            elementText(preview).contains("struct SeedCatalog {}"),
            "The preview should show the selected code, found: \(elementText(preview))"
        )
        XCTAssertTrue(
            comments.descendantText(containing: "before line 8").waitForExistence(timeout: 5),
            "A mixed selection should keep its removed side and line"
        )
        XCTAssertTrue(
            comments.descendantText(containing: "after line 12").waitForExistence(timeout: 5),
            "A mixed selection should keep its context lines"
        )

        // A long excerpt keeps the full saved selection available.
        let expand = comments.descendantButton(titled: "Show full selection")
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "More than three saved lines should offer the full excerpt")
        expand.click()
        XCTAssertTrue(comments.descendantButton(titled: "Show less").waitForExistence(timeout: 5))

        // Copy comment is the manual-publishing path: exact text, nothing else.
        let copy = comments.descendantButton(titled: "Copy comment")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Each comment should offer Copy comment")
        copy.click()
        XCTAssertTrue(waitForPasteboard(body), "Copy comment must copy only the exact saved Markdown")

        // The GitHub handoff is offered but no automated test may activate it.
        XCTAssertTrue(
            comments.descendantButton(titled: "Open file in GitHub").waitForExistence(timeout: 5),
            "Each comment should offer the PR file link"
        )
        XCTAssertTrue(comments.descendantButton(titled: "Show in diff").exists)
    }

    // MARK: - Local location navigation

    @MainActor
    func testShowInDiffClearsFiltersAndRestoresTheSavedLocation() {
        let app = launchDemoApp(commentStoreURL: temporaryCommentStoreDirectory())
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))

        saveSelectionComment(in: main, app: app, body: "Navigate back to the saved seed catalog lines")

        // Hide every file, then leave the Files tab entirely. Show in diff has
        // to clear both obstacles on its way to the saved anchor.
        let search = main.textFields["Filter files"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("no-synthetic-file-matches-this-filter")
        XCTAssertTrue(
            main.descendant(identifier: "pr-review-no-filter-matches").waitForExistence(timeout: 5),
            "The synthetic filter should hide every file"
        )
        selectTab("Context", expectedContentIdentifier: "pr-review-context", in: main)

        let comments = openCommentsList(in: main, app: app)
        let show = comments.descendantButton(titled: "Show in diff")
        XCTAssertTrue(show.waitForExistence(timeout: 5), "Each comment should offer Show in diff")
        show.click()

        XCTAssertTrue(
            app.control(identifier: "pr-review-comments").waitForNonExistence(timeout: 5),
            "Show in diff should dismiss the comments list"
        )
        XCTAssertTrue(
            main.descendant(identifier: "pr-review-file-0").waitForExistence(timeout: 10),
            "Show in diff should return to the Files tab with the filters cleared"
        )
        XCTAssertFalse(
            main.descendant(identifier: "pr-review-no-filter-matches").exists,
            "Show in diff must actually clear the obstructing filter"
        )
        let savedPath = main.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", SyntheticPRReview.firstPath, SyntheticPRReview.firstPath)
        ).firstMatch
        XCTAssertTrue(
            savedPath.waitForExistence(timeout: 10),
            "Show in diff should select the file the comment was saved on"
        )
    }

    // MARK: - Shared windows and review isolation

    @MainActor
    func testMainAndPopOutShareCommentsWhileAnotherReviewStaysIsolated() {
        let app = launchDemoApp(commentStoreURL: temporaryCommentStoreDirectory())
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))

        let original = "Shared comment from the main window\nSecond line stays exact"
        saveSelectionComment(in: main, app: app, body: original)

        // Pop the review out; the new window observes the shared record.
        let row = main.buttons[SyntheticPRReview.rowIdentifier(SyntheticPRReview.firstReviewID)]
        bringForward(row, in: app)
        choosePopOut(SyntheticPRReview.firstReviewID, from: row, in: app)
        let popout = waitForReviewWindow(SyntheticPRReview.firstReviewID, in: app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: popout))

        let popoutComments = openCommentsList(
            in: popout,
            app: app,
            windowTitle: SyntheticPRReview.firstTitle
        )
        assertCommentBody(original, in: popoutComments)

        // Edit in the pop-out; the main window must observe the same text.
        let edit = popoutComments.descendantButton(titled: "Edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Each comment should offer Edit")
        edit.click()
        let prefill = waitForFirst(of: [
            app.textViews["pr-review-comment-body"],
            app.control(identifier: "pr-review-comment-body"),
        ], timeout: 10)
        XCTAssertEqual(
            prefill?.value as? String,
            original,
            "Edit should prefill the exact saved text"
        )
        let edited = original + " (edited in the pop-out)"
        guard let bodyField = typeCommentBody(edited, in: app, clearing: true) else {
            XCTFail("Edit should open the local comment editor with its saved text")
            return
        }
        XCTAssertEqual(
            bodyField.value as? String,
            edited,
            "The editor should hold the exact edited text"
        )
        let save = app.control(identifier: "pr-review-comment-save")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        waitUntilEnabled(save)
        save.click()
        XCTAssertTrue(app.control(identifier: "pr-review-comment-editor").waitForNonExistence(timeout: 5))
        assertCommentBody(edited, in: popoutComments)
        closeCommentsList(in: app)

        let mainComments = openCommentsList(in: main, app: app)
        assertCommentBody(edited, in: mainComments)
        closeCommentsList(in: app)

        // Another review is a separate scope: its list starts empty.
        selectReview(
            SyntheticPRReview.secondReviewID,
            in: main,
            app: app,
            expectedDiff: SyntheticPRReview.secondDiff
        )
        let secondComments = openCommentsList(in: main, app: app)
        XCTAssertTrue(
            secondComments.descendant(identifier: "pr-review-comments-empty").waitForExistence(timeout: 5),
            "A review without comments should show its own empty list"
        )
        XCTAssertFalse(
            commentElement(prefix: "pr-review-comment-body-", in: secondComments).exists,
            "The first review's comment must not leak into the second review"
        )
        closeCommentsList(in: app)

        // A comment on the second review is still invisible to the first.
        saveSelectionComment(in: main, app: app, body: "Reminder-only synthetic comment")
        selectReview(
            SyntheticPRReview.firstReviewID,
            in: main,
            app: app,
            expectedDiff: SyntheticPRReview.firstDiff
        )
        let reviewOneComments = openCommentsList(in: main, app: app)
        assertCommentBody(edited, in: reviewOneComments)
        XCTAssertFalse(
            reviewOneComments.descendantText(containing: "Reminder-only synthetic comment").exists,
            "The second review's comment must not leak into the first review"
        )
        closeCommentsList(in: app)
    }

    // MARK: - Relaunch persistence

    @MainActor
    func testSavedCommentSurvivesTerminationAndRelaunchWithTheSameStore() {
        let storeURL = temporaryCommentStoreDirectory()
        let app = launchDemoApp(commentStoreURL: storeURL)
        defer { app.terminate() }
        let main = openPRReview(app)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: main))

        let body = "Survives termination\nSecond line stays exact"
        saveSelectionComment(in: main, app: app, body: body)
        app.terminate()

        let relaunched = launchDemoApp(commentStoreURL: storeURL)
        defer { relaunched.terminate() }
        let restored = openPRReview(relaunched)
        XCTAssertTrue(waitForDiffText(SyntheticPRReview.firstDiff, in: restored))

        let comments = openCommentsList(in: restored, app: relaunched)
        assertCommentBody(body, in: comments)
        XCTAssertFalse(
            comments.descendant(identifier: "pr-review-comments-storage-error").exists,
            "A store written by the same version should load without a storage error"
        )
        let preview = commentElement(prefix: "pr-review-comment-preview-", in: comments)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(elementText(preview).contains("struct SeedCatalog {}"))
        XCTAssertTrue(comments.descendantButton(titled: "Show in diff").exists)
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

        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Add comment")
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
            app.control(identifier: "pr-review-comment-editor").waitForExistence(timeout: 10),
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
            app.textViews["pr-review-comment-body"],
            app.control(identifier: "pr-review-comment-body"),
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
        guard let field = typeCommentBody(body, in: app) else {
            XCTFail("The comment editor should expose its multiline body")
            return
        }
        XCTAssertEqual(
            field.value as? String,
            body,
            "The editor must keep the exact typed text before saving"
        )
        let save = app.control(identifier: "pr-review-comment-save")
        XCTAssertTrue(save.waitForExistence(timeout: 5), "The editor should expose Save")
        waitUntilEnabled(save)
        save.click()
        XCTAssertTrue(
            app.control(identifier: "pr-review-comment-editor").waitForNonExistence(timeout: 5),
            "A successful save should close the editor"
        )
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

        var sheet = waitForFirst(of: [
            window.descendant(identifier: "pr-review-comments"),
            app.control(identifier: "pr-review-comments"),
        ], timeout: 5)
        if sheet == nil {
            // A first click can land while the window is still activating.
            button.click()
            sheet = waitForFirst(of: [
                window.descendant(identifier: "pr-review-comments"),
                app.control(identifier: "pr-review-comments"),
            ], timeout: 5)
        }
        guard let sheet else {
            XCTFail("The Comments control should open the review-wide list")
            return app.control(identifier: "pr-review-comments")
        }
        return sheet
    }

    @MainActor
    private func closeCommentsList(in app: XCUIApplication) {
        let done = waitForFirst(of: [
            app.control(identifier: "pr-review-comments-done"),
            app.buttons["Done"],
        ], timeout: 5)
        XCTAssertNotNil(done)
        done?.click()
        XCTAssertTrue(
            app.control(identifier: "pr-review-comments").waitForNonExistence(timeout: 5),
            "Done should close the review-wide comments list"
        )
    }

    /// Verifies the saved text is readable in the list without pinning AppKit's
    /// choice of AXLabel versus AXValue for a multiline `Text`.
    @MainActor
    private func assertCommentBody(
        _ body: String,
        in sheet: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = commentElement(prefix: "pr-review-comment-body-", in: sheet)
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("The list should show the saved comment text", file: file, line: line)
            return
        }
        let observed = elementText(element)
        for fragment in body.components(separatedBy: "\n") where !fragment.isEmpty {
            XCTAssertTrue(
                observed.contains(fragment),
                "Expected “\(fragment)” in the saved comment, found: \(observed)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func commentElement(prefix: String, in scope: XCUIElement) -> XCUIElement {
        scope.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    @MainActor
    private func elementText(_ element: XCUIElement) -> String {
        let value = element.value as? String ?? ""
        return value.isEmpty ? element.label : "\(element.label) \(value)"
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
        item.click()
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
