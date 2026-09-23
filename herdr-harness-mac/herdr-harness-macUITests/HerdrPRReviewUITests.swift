import XCTest

/// Interactive acceptance coverage for the PR Review pop-out windows.
///
/// Everything here runs against the synthetic `-HerdrDemoMode` fleet: two
/// active reviews, two chats, no server, no private configuration. Queries are
/// always scoped to a window identified by its machine/review target rather
/// than `windows.firstMatch`, because the feature under test is precisely that
/// several review windows can sit beside the main window at once.
final class HerdrPRReviewUITests: HerdrUITestCase {
    private let screenshotDirectory = HerdrPRReviewUITests.resolvedScreenshotDirectory()

    @MainActor
    func testEmptyFileFilterKeepsControlsAtTheTop() throws {
        let app = launchDemoApp()
        defer { app.terminate() }
        _ = openPRReview(app)
        let main = mainWindow(in: app)
        let impact = control("pr-review-impact-filter", in: main)
        XCTAssertTrue(impact.waitForExistence(timeout: 10))
        let initialY = impact.frame.minY
        let search = main.textFields["Filter files"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("no-synthetic-file-matches-this-filter")
        XCTAssertTrue(control("pr-review-no-filter-matches", in: main).waitForExistence(timeout: 5))
        XCTAssertEqual(impact.frame.minY, initialY, accuracy: 3,
                       "The Impact control must not become vertically centered when its list is empty")
        main.buttons["Clear filters"].click()
        XCTAssertTrue(control("pr-review-file-0", in: main).waitForExistence(timeout: 5))
        XCTAssertEqual(impact.frame.minY, initialY, accuracy: 3)
    }

    // MARK: - Context menus and window identity

    @MainActor
    func testRowAndHeaderContextMenusOpenDistinctReviewWindows() throws {
        let app = launchDemoApp()
        defer { app.terminate() }

        _ = openPRReview(app)
        let main = mainWindow(in: app)
        XCTAssertTrue(
            headerTitle(SyntheticReview.firstTitle, in: main).waitForExistence(timeout: 10),
            "The first synthetic review should be selected when PR Review opens"
        )

        // The first review is selected, so the second row is the unselected one.
        let secondRow = main.buttons[SyntheticReview.rowIdentifier(SyntheticReview.secondID)]
        choosePopOut(SyntheticReview.secondID, from: secondRow, in: app)

        let secondWindow = waitForReviewWindow(SyntheticReview.secondID, in: app)
        expectReviewWindowContent(
            secondWindow,
            title: SyntheticReview.secondTitle,
            diffText: SyntheticReview.secondDiff
        )
        XCTAssertEqual(
            reviewWindows(in: app, reviewID: SyntheticReview.secondID).count,
            1,
            "Each review should own exactly one window"
        )
        XCTAssertTrue(
            headerTitle(SyntheticReview.firstTitle, in: main).exists,
            "Popping out an unselected row must not change the main window's selection"
        )

        // The displayed review's header carries the same action. The
        // additions/deletions summary exists only in the detail header, so the
        // anchor cannot land on a same-titled sidebar row.
        let header = headerAnchor(in: main)
        bringForward(header, in: app)
        choosePopOut(SyntheticReview.firstID, from: header, in: app)

        let firstWindow = waitForReviewWindow(SyntheticReview.firstID, in: app)
        expectReviewWindowContent(
            firstWindow,
            title: SyntheticReview.firstTitle,
            diffText: SyntheticReview.firstDiff
        )
        XCTAssertTrue(secondWindow.exists, "The first review window must stay open beside the second")
        XCTAssertTrue(
            headerTitle(SyntheticReview.secondTitle, in: secondWindow).exists,
            "Each window should keep its own review identity"
        )

        // Reopening a review focuses the window it already owns.
        bringForward(secondRow, in: app)
        choosePopOut(SyntheticReview.secondID, from: secondRow, in: app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(
            reviewWindows(in: app, reviewID: SyntheticReview.secondID).count,
            1,
            "Reopening the same machine/review should focus its existing window"
        )

        // Closing one window neither closes the other nor archives its review.
        let close = secondWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "A review window should be closable")
        bringForward(close, in: app, windowTitle: SyntheticReview.secondTitle)
        close.click()
        XCTAssertTrue(secondWindow.waitForNonExistence(timeout: 5))
        XCTAssertTrue(firstWindow.exists, "Closing one review window must not close another")
        XCTAssertTrue(mainWindow(in: app).exists, "Closing a review window must not close the main window")

        XCTAssertTrue(
            secondRow.waitForExistence(timeout: 5),
            "Closing a review window is presentation-only, not archiving"
        )
        bringForward(secondRow, in: app)
        choosePopOut(SyntheticReview.secondID, from: secondRow, in: app)
        let reopened = waitForReviewWindow(SyntheticReview.secondID, in: app)
        expectReviewWindowContent(
            reopened,
            title: SyntheticReview.secondTitle,
            diffText: SyntheticReview.secondDiff
        )
        XCTAssertTrue(firstWindow.exists)
        XCTAssertEqual(reviewWindows(in: app, reviewID: SyntheticReview.secondID).count, 1)

        saveScreenshot("pr-review-two-windows", app: app, directory: screenshotDirectory)
        saveWindowScreenshot("pr-review-window-first", window: firstWindow, directory: screenshotDirectory)
        saveWindowScreenshot("pr-review-window-second", window: reopened, directory: screenshotDirectory)
    }

    // MARK: - Concurrent chat navigation

    @MainActor
    func testReviewWindowStaysOpenWhileNavigatingChatsWithAnUnsentDraft() throws {
        let app = launchDemoApp()
        defer { app.terminate() }

        _ = openPRReview(app)
        let main = mainWindow(in: app)
        choosePopOut(
            SyntheticReview.firstID,
            from: main.buttons[SyntheticReview.rowIdentifier(SyntheticReview.firstID)],
            in: app
        )
        let reviewWindow = waitForReviewWindow(SyntheticReview.firstID, in: app)
        expectReviewWindowContent(
            reviewWindow,
            title: SyntheticReview.firstTitle,
            diffText: SyntheticReview.firstDiff
        )

        // Return to the chats while the review window stays open.
        let back = main.buttons["All sessions"]
        bringForward(back, in: app)
        back.click()
        XCTAssertTrue(
            main.buttons["sidebar-pane-demo1|w1:p2"].waitForExistence(timeout: 10),
            "All sessions should restore the chat navigator"
        )

        main.buttons["sidebar-pane-demo1|w1:p2"].click()
        // These fixtures are Claude/Codex sessions, not semantic Pi chats.
        // Their native session composer is available in Terminal mode.
        let editor = main.textViews["prompt-composer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Synthetic garden draft")
        XCTAssertEqual(editor.value as? String, "Synthetic garden draft")

        // Navigate to a second chat.
        main.buttons["sidebar-pane-demo1|w2:p1"].click()
        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w2:p1").waitForExistence(timeout: 10),
            "The second synthetic chat should open in the main window"
        )

        // The review window kept its review, its file, and its controls.
        expectReviewWindowContent(
            reviewWindow,
            title: SyntheticReview.firstTitle,
            diffText: SyntheticReview.firstDiff
        )
        XCTAssertTrue(control("pr-review-mode-picker", in: reviewWindow).exists)
        XCTAssertTrue(control("pr-review-file-0", in: reviewWindow).exists)

        // Returning restores the unsent draft untouched.
        main.buttons["sidebar-pane-demo1|w1:p2"].click()
        let restored = main.textViews["prompt-composer"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(
            restored.value as? String,
            "Synthetic garden draft",
            "Chat navigation must preserve an unsent draft while a review window is open"
        )

        saveScreenshot("pr-review-chat-and-window", app: app, directory: screenshotDirectory)

        // Closing a window is not archiving: both active reviews stay listed.
        main.buttons["open-pr-review"].click()
        XCTAssertTrue(
            main.buttons[SyntheticReview.rowIdentifier(SyntheticReview.firstID)].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(main.buttons[SyntheticReview.rowIdentifier(SyntheticReview.secondID)].exists)
        XCTAssertTrue(reviewWindow.exists)
    }

    // MARK: - Independent windows, tabs, and Ask AI

    @MainActor
    func testTwoReviewWindowsKeepIndependentTabsAndReachEveryWorkspaceTab() throws {
        let app = launchDemoApp()
        defer { app.terminate() }

        _ = openPRReview(app)
        let main = mainWindow(in: app)

        choosePopOut(
            SyntheticReview.firstID,
            from: main.buttons[SyntheticReview.rowIdentifier(SyntheticReview.firstID)],
            in: app
        )
        let firstWindow = waitForReviewWindow(SyntheticReview.firstID, in: app)
        let secondRow = main.buttons[SyntheticReview.rowIdentifier(SyntheticReview.secondID)]
        bringForward(secondRow, in: app)
        choosePopOut(
            SyntheticReview.secondID,
            from: secondRow,
            in: app
        )
        let secondWindow = waitForReviewWindow(SyntheticReview.secondID, in: app)

        expectReviewWindowContent(
            firstWindow,
            title: SyntheticReview.firstTitle,
            diffText: SyntheticReview.firstDiff
        )
        expectReviewWindowContent(
            secondWindow,
            title: SyntheticReview.secondTitle,
            diffText: SyntheticReview.secondDiff
        )
        XCTAssertEqual(reviewWindows(in: app, reviewID: SyntheticReview.firstID).count, 1)
        XCTAssertEqual(reviewWindows(in: app, reviewID: SyntheticReview.secondID).count, 1)

        // A tab switch in one window leaves the other on its own review.
        selectTab("Context", in: firstWindow, app: app)
        XCTAssertTrue(
            control("pr-review-context", in: firstWindow).waitForExistence(timeout: 10),
            "The popped-out window should reach the Context tab"
        )
        expectReviewWindowContent(
            secondWindow,
            title: SyntheticReview.secondTitle,
            diffText: SyntheticReview.secondDiff
        )

        selectTab("Agents", in: firstWindow, app: app)
        XCTAssertTrue(
            control("pr-review-agents", in: firstWindow).waitForExistence(timeout: 10),
            "The popped-out window should reach the Agents tab"
        )

        selectTab("Skills", in: firstWindow, app: app)
        XCTAssertTrue(
            control("pr-review-skills", in: firstWindow).waitForExistence(timeout: 10),
            "The popped-out window should reach the Skills tab"
        )

        selectTab("Files", in: firstWindow, app: app)
        XCTAssertTrue(
            control("pr-review-file-0", in: firstWindow).waitForExistence(timeout: 10),
            "The popped-out window should return to its own Files list"
        )

        // Selecting a different file in one window never retargets the other.
        let secondFile = control("pr-review-file-1", in: secondWindow)
        bringForward(secondFile, in: app, windowTitle: SyntheticReview.secondTitle)
        secondFile.click()
        XCTAssertTrue(
            secondWindow.staticTexts
                .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Tests/WateringTests.swift", "Tests/WateringTests.swift"))
                .firstMatch
                .waitForExistence(timeout: 10),
            "The second window should select its own file"
        )
        expectReviewWindowContent(
            firstWindow,
            title: SyntheticReview.firstTitle,
            diffText: SyntheticReview.firstDiff
        )

        // Ask AI stays reachable through the popped-out diff's context menu.
        let diff = firstWindow.webViews.firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 10))
        bringForward(diff, in: app, windowTitle: SyntheticReview.firstTitle)
        diff.click()
        app.typeKey("a", modifierFlags: .command)
        diff.rightClick()
        XCTAssertTrue(
            waitForFirst(
                of: [
                    app.textFields["pr-review-ask-field"],
                    app.control(identifier: "pr-review-ask-field"),
                    app.control(labelContaining: "Ask AI about selection"),
                ],
                timeout: 5
            ) != nil,
            "Ask AI should present its question field in the popped-out window; tree: \(app.debugDescription)"
        )

        let question = app.control(identifier: "pr-review-ask-field")
        question.click()
        question.typeText("Explain this synthetic selection briefly")
        app.buttons["pr-review-send-question"].click()
        let saved = firstWindow.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Explain this synthetic selection briefly")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "Sending a question must leave a durable bubble in the diff")
        bringForward(saved, in: app, windowTitle: SyntheticReview.firstTitle)
        saved.click()
        let answer = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Ask Herdr · PR #42")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "The saved bubble must reopen its conversation")
        answer.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(saved.exists, "Closing the answer must not remove its saved bubble")

        saveWindowScreenshot("pr-review-pop-out-ask-ai", window: firstWindow, directory: screenshotDirectory)
        saveWindowScreenshot("pr-review-pop-out-second", window: secondWindow, directory: screenshotDirectory)
    }

    // MARK: - Deleted-file disclosure

    @MainActor
    func testDeletedFilesAreMarkedCollapsedAndExpandThroughControls() throws {
        let app = launchDemoApp()
        defer { app.terminate() }
        _ = openPRReview(app)
        let main = mainWindow(in: app)

        // R1: a modified file that contains removal lines is never labeled deleted.
        let modifiedRow = control("pr-review-file-0", in: main)
        XCTAssertTrue(modifiedRow.waitForExistence(timeout: 10))
        XCTAssertEqual(deletedBadgeCount(in: modifiedRow), 0,
                       "A modified file with removal lines must not carry a Deleted badge")
        XCTAssertFalse(control("pr-review-deleted-indicator", in: main).exists)

        // R1/R3: filtering leaves the deleted source file as the only visible row,
        // so the rail badge and the collapsed default are unambiguous.
        setFileFilter(SyntheticReview.deletedSourceSearchTerm, in: main, app: app)
        let deletedRow = control("pr-review-file-0", in: main)
        XCTAssertTrue(deletedRow.waitForExistence(timeout: 5))
        let deletedBadge = control("pr-review-file-deleted-0", in: main)
        XCTAssertTrue(deletedBadge.waitForExistence(timeout: 5),
                      "The file rail should label a deleted file with readable text")
        XCTAssertEqual(deletedBadge.label, "Deleted file")
        deletedRow.click()

        XCTAssertTrue(headerPath(SyntheticReview.deletedSourcePath, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-deleted-indicator", in: main).waitForExistence(timeout: 5),
                      "The selected deleted file's header should repeat the Deleted indicator")
        XCTAssertTrue(text(SyntheticReview.deletedSourceSummary, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 10),
                      "A selected deleted file should explain that its content is hidden")
        XCTAssertTrue(main.webViews.firstMatch.waitForNonExistence(timeout: 5),
                      "A collapsed deleted file must not mount the code renderer")

        let disclosure = control("pr-review-deleted-content-disclosure", in: main)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertEqual(disclosure.label, "Show deleted content")
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        XCTAssertTrue(disclosure.isEnabled)

        // R2 pointer path: Show deleted content reveals the removal hunk and
        // the same control hides it again.
        disclosure.click()
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main),
                      "Expanding a deleted source file must reveal its removed code")
        XCTAssertEqual(disclosure.label, "Hide deleted content")
        XCTAssertEqual(disclosure.value as? String, "Expanded")
        disclosure.click()
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(main.webViews.firstMatch.waitForNonExistence(timeout: 5),
                      "Hide deleted content must unmount the code renderer")
        XCTAssertEqual(disclosure.value as? String, "Collapsed")

        // R2 keyboard path: Tab establishes focus on the disclosure and Space
        // expands and collapses it. No pointer press touches the disclosure
        // below, so this only passes when keyboard activation really works.
        setFileFilter(SyntheticReview.deletedSourceSearchTerm, in: main, app: app)
        focusWithTab(disclosure, in: main, app: app)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main),
                      "Space on the keyboard-focused disclosure must expand deleted content")
        XCTAssertEqual(disclosure.value as? String, "Expanded")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5),
                      "Space on the keyboard-focused disclosure must collapse deleted content")
        XCTAssertEqual(disclosure.value as? String, "Collapsed")

        // Disclosure survives keyboard file navigation in both states.
        setFileFilter("Legacy", in: main, app: app)
        XCTAssertTrue(control("pr-review-file-1", in: main).waitForExistence(timeout: 5))
        disclosure.click()
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main))
        app.typeKey(.downArrow, modifierFlags: .option)
        XCTAssertTrue(headerPath(SyntheticReview.deletedLongPath, in: main).waitForExistence(timeout: 5),
                      "⌥↓ should move keyboard selection to the next deleted file")
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5),
                      "A deleted file the reviewer has not disclosed stays collapsed")
        app.typeKey(.upArrow, modifierFlags: .option)
        XCTAssertTrue(headerPath(SyntheticReview.deletedSourcePath, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main),
                      "An expanded deleted file stays expanded after navigating away and back")
        disclosure.click()
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))
        app.typeKey(.downArrow, modifierFlags: .option)
        app.typeKey(.upArrow, modifierFlags: .option)
        XCTAssertTrue(headerPath(SyntheticReview.deletedSourcePath, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5),
                      "A collapsed deleted file stays collapsed across keyboard navigation")

        // Long path: the complete path stays accessible and disclosure works.
        app.typeKey(.downArrow, modifierFlags: .option)
        XCTAssertTrue(headerPath(SyntheticReview.deletedLongPath, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-deleted-indicator", in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(text(SyntheticReview.deletedLongPathSummary, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))
        disclosure.click()
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedLongPathRemovedLine, in: main),
                      "A long-path deleted file expands like any other")
        disclosure.click()
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))

        // Prose: the same disclosure works for a deleted document.
        setFileFilter(SyntheticReview.deletedProseSearchTerm, in: main, app: app)
        let proseRow = control("pr-review-file-0", in: main)
        XCTAssertTrue(proseRow.waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-file-deleted-0", in: main).waitForExistence(timeout: 5))
        proseRow.click()
        XCTAssertTrue(headerPath(SyntheticReview.deletedProsePath, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-deleted-indicator", in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(text(SyntheticReview.deletedProseSummary, in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(main.webViews.firstMatch.waitForNonExistence(timeout: 5))
        disclosure.click()
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedProseRemovedLine, in: main),
                      "Expanding a deleted prose file must reveal its removed text")
        disclosure.click()
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))

        // Ask AI on expanded removed code. A nonempty draft blocks collapse.
        setFileFilter(SyntheticReview.deletedSourceSearchTerm, in: main, app: app)
        let sourceRow = control("pr-review-file-0", in: main)
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 5))
        sourceRow.click()
        disclosure.click()
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main))
        let diff = main.webViews.firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 10))
        diff.click()
        app.typeKey("a", modifierFlags: .command)
        diff.rightClick()
        guard let question = waitForFirst(
            of: [app.textFields["pr-review-ask-field"], app.control(identifier: "pr-review-ask-field")],
            timeout: 5
        ) else {
            XCTFail("Selecting removed code should offer Ask AI; tree: \(app.debugDescription)")
            return
        }
        question.click()
        question.typeText(SyntheticReview.deletedSourceQuestion)
        XCTAssertEqual(question.value as? String, SyntheticReview.deletedSourceQuestion)
        XCTAssertTrue(waitForDisabled(disclosure),
                      "A nonempty Ask AI draft must protect the expanded deleted content")
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main),
                      "The removed code stays visible while the draft is open")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(waitForEnabled(disclosure), "Cancelling the draft should re-enable the disclosure")
        disclosure.click()
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(main.webViews.firstMatch.waitForNonExistence(timeout: 5))

        saveScreenshot("pr-review-deleted-files", app: app, directory: screenshotDirectory)
    }

    @MainActor
    func testDeletedDisclosureIsIndependentBetweenMainAndPopOutWindows() throws {
        let app = launchDemoApp()
        defer { app.terminate() }
        _ = openPRReview(app)
        let main = mainWindow(in: app)

        setFileFilter(SyntheticReview.deletedSourceSearchTerm, in: main, app: app)
        let row = control("pr-review-file-0", in: main)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        let mainDisclosure = control("pr-review-deleted-content-disclosure", in: main)
        XCTAssertTrue(mainDisclosure.waitForExistence(timeout: 10))
        XCTAssertEqual(mainDisclosure.value as? String, "Collapsed")
        mainDisclosure.click()
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main))

        choosePopOut(SyntheticReview.firstID, from: headerAnchor(in: main), in: app)
        let window = waitForReviewWindow(SyntheticReview.firstID, in: app)
        let windowDisclosure = control("pr-review-deleted-content-disclosure", in: window)
        XCTAssertTrue(windowDisclosure.waitForExistence(timeout: 10))
        XCTAssertEqual(windowDisclosure.value as? String, "Collapsed",
                       "A popped-out window starts with its own collapsed deleted content")
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: window).waitForExistence(timeout: 5))
        XCTAssertTrue(window.webViews.firstMatch.waitForNonExistence(timeout: 5))

        windowDisclosure.click()
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: window))
        XCTAssertEqual(mainDisclosure.value as? String, "Expanded",
                       "Expanding in the pop-out must not collapse the main window")
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: main))

        bringForward(mainDisclosure, in: app)
        mainDisclosure.click()
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: main).waitForExistence(timeout: 5))
        XCTAssertTrue(main.webViews.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(windowDisclosure.value as? String, "Expanded",
                       "Collapsing in the main window must not collapse the pop-out")
        XCTAssertTrue(waitForDiffText(SyntheticReview.deletedSourceRemovedLine, in: window))

        bringForward(windowDisclosure, in: app, windowTitle: SyntheticReview.firstTitle)
        windowDisclosure.click()
        XCTAssertTrue(control("pr-review-deleted-content-hidden", in: window).waitForExistence(timeout: 5))

        saveWindowScreenshot("pr-review-deleted-window", window: window, directory: screenshotDirectory)
    }

    // MARK: - Shared steps

    /// Opens the review rail and returns with both synthetic active reviews
    /// settled, so every later step anchors on real rows.
    @MainActor
    @discardableResult
    private func openPRReview(_ app: XCUIApplication) -> XCUIElement {
        let open = app.control(identifier: "open-pr-review")
        XCTAssertTrue(open.waitForExistence(timeout: 10), "The navigator should expose PR Review")
        open.click()

        let firstRow = app.buttons[SyntheticReview.rowIdentifier(SyntheticReview.firstID)]
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 10),
            "Demo mode should list the first synthetic active review"
        )
        XCTAssertTrue(
            app.buttons[SyntheticReview.rowIdentifier(SyntheticReview.secondID)].waitForExistence(timeout: 5),
            "Demo mode should list both synthetic active reviews"
        )
        return firstRow
    }

    @MainActor
    private func choosePopOut(
        _ reviewID: String,
        from anchor: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(anchor.waitForExistence(timeout: 10), "The context-menu anchor should exist", file: file, line: line)
        anchor.rightClick()

        let identifier = SyntheticReview.popOutIdentifier(reviewID)
        guard let item = waitForFirst(
            of: [
                app.menuItems[identifier],
                app.menuItems["Pop Out into Window"],
                app.control(identifier: identifier),
            ],
            timeout: 5
        ) else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Right-clicking should offer Pop Out into Window", file: file, line: line)
            return
        }
        item.click()
    }

    /// Clicks one tab in a review window's segmented picker. The segment label
    /// carries a count ("Context (4)", "Agents (1 running)"), so the match is a
    /// label prefix across every Mac role a segment can publish.
    @MainActor
    private func selectTab(
        _ title: String,
        in window: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = control("pr-review-mode-picker", in: window)
        guard picker.waitForExistence(timeout: 10) else {
            XCTFail("The popped-out window should expose its tab picker", file: file, line: line)
            return
        }

        let prefix = NSPredicate(format: "label BEGINSWITH[c] %@", title)
        guard let segment = waitForFirst(
            of: [
                picker.buttons[title],
                picker.radioButtons[title],
                picker.descendants(matching: .any).matching(prefix).firstMatch,
            ],
            timeout: 5
        ) else {
            XCTFail("The tab picker should offer \(title)", file: file, line: line)
            return
        }
        bringForward(segment, in: app, windowTitle: SyntheticReview.firstTitle)
        segment.click()
    }

    // MARK: - Window-scoped queries

    /// Any element carrying `identifier` inside `window`, whatever Mac role it
    /// publishes.
    @MainActor
    private func control(_ identifier: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func headerTitle(_ title: String, in window: XCUIElement) -> XCUIElement {
        window.staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
    }

    /// The complete path in the selected-file header, where long paths stay
    /// available to accessibility even when the row truncates for layout.
    @MainActor
    private func headerPath(_ path: String, in window: XCUIElement) -> XCUIElement {
        window.staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", path, path))
            .firstMatch
    }

    /// Visible SwiftUI text scoped to one window, matching either AXLabel or
    /// AXValue. The app-wide helper in the support file cannot be scoped.
    @MainActor
    private func text(_ fragment: String, in window: XCUIElement) -> XCUIElement {
        window.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", fragment, fragment))
            .firstMatch
    }

    /// How many textual Deleted badges a file row publishes.
    @MainActor
    private func deletedBadgeCount(in row: XCUIElement) -> Int {
        row.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label == %@ OR identifier BEGINSWITH %@",
                "Deleted file",
                "pr-review-file-deleted-"
            ))
            .count
    }

    /// Replaces the rail search text while keeping file order deterministic.
    @MainActor
    private func setFileFilter(
        _ term: String,
        in window: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let search = window.textFields["Filter files"]
        XCTAssertTrue(
            search.waitForExistence(timeout: 5),
            "The review rail should keep its file filter",
            file: file,
            line: line
        )
        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText(term)
    }

    /// Polls for a deleted file's removed text in the window's mounted renderer.
    @MainActor
    private func waitForDiffText(
        _ fragment: String,
        in window: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let diff = window.webViews.firstMatch
        guard diff.waitForExistence(timeout: timeout) else { return false }
        let expected = fragment.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let rendered = diff.staticTexts.allElementsBoundByIndex.map {
                ($0.value as? String) ?? $0.label
            }.joined()
            if rendered.filter({ !$0.isWhitespace }).contains(expected) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return element.exists && element.isEnabled
    }

    @MainActor
    private func waitForDisabled(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && !element.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return element.exists && !element.isEnabled
    }

    /// Whether `element` owns keyboard focus. macOS does not expose
    /// `XCUIElement.hasFocus`, but XCUITest matches the AX
    /// `hasKeyboardFocus` attribute through a predicate.
    @MainActor
    private func hasKeyboardFocus(_ element: XCUIElement, in window: XCUIElement) -> Bool {
        guard element.exists, !element.identifier.isEmpty else { return false }
        return window.descendants(matching: .any)
            .matching(identifier: element.identifier)
            .matching(NSPredicate(format: "hasKeyboardFocus == 1"))
            .firstMatch
            .exists
    }

    /// Moves keyboard focus onto `element` with Tab alone and fails rather
    /// than clicking, so the assertions that follow are keyboard-only.
    @MainActor
    private func focusWithTab(
        _ element: XCUIElement,
        in window: XCUIElement,
        app: XCUIApplication,
        attempts: Int = 64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !hasKeyboardFocus(element, in: window) else { return }
        for _ in 0..<attempts {
            app.typeKey(.tab, modifierFlags: [])
            if hasKeyboardFocus(element, in: window) { return }
        }
        XCTFail("Tab should move keyboard focus onto the deleted-content disclosure", file: file, line: line)
    }

    /// The header's additions/deletions summary is unique to the review detail,
    /// which keeps the header context menu test off the same-titled sidebar row.
    @MainActor
    private func headerAnchor(in main: XCUIElement) -> XCUIElement {
        let container = control("pr-review-container", in: main)
        let scope = container.exists ? container : main
        return scope.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", SyntheticReview.firstAdditionsSummary, SyntheticReview.firstAdditionsSummary))
            .firstMatch
    }

    /// The main shell window always carries the history toolbar; review windows
    /// never do. This is how every main-window query stays scoped to it.
    @MainActor
    private func mainWindow(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        // Keep the identity predicate in the query. An element bound to a
        // global window index silently retargets when another window opens.
        let window = app.windows.containing(.any, identifier: "nav-history-controls").firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "The main shell window should stay addressable beside review windows",
            file: file,
            line: line
        )
        return window
    }

    /// Every window whose review root carries this machine/review target.
    /// Retain that predicate so later window ordering cannot retarget a query.
    /// Counting matches still makes "no duplicate window" a real assertion.
    @MainActor
    private func reviewWindows(in app: XCUIApplication, reviewID: String) -> [XCUIElement] {
        let identifier = SyntheticReview.windowIdentifier(reviewID)
        return app.windows.containing(.any, identifier: identifier).allElementsBoundByIndex
    }

    @MainActor
    private func waitForReviewWindow(
        _ reviewID: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = reviewWindows(in: app, reviewID: reviewID).first { return window }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline

        XCTFail("A review window for \(reviewID) should open", file: file, line: line)
        return app.windows.firstMatch
    }

    @MainActor
    private func expectReviewWindowContent(
        _ window: XCUIElement,
        title: String,
        diffText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            headerTitle(title, in: window).waitForExistence(timeout: 10),
            "A review window should show the \(title) header",
            file: file,
            line: line
        )

        let diff = window.webViews.firstMatch
        XCTAssertTrue(
            diff.waitForExistence(timeout: 10),
            "A review window should mount the shared diff",
            file: file,
            line: line
        )
        let expected = diffText.filter { !$0.isWhitespace }
        var rendered = ""
        let deadline = Date().addingTimeInterval(10)
        repeat {
            // WebKit's macOS AXStaticText exposes code as its value, not label.
            rendered = diff.staticTexts.allElementsBoundByIndex.map {
                ($0.value as? String) ?? $0.label
            }.joined()
            if rendered.filter({ !$0.isWhitespace }).contains(expected) { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTAssertTrue(
            rendered.filter({ !$0.isWhitespace }).contains(expected),
            "A review window should render its own diff text, found: \(rendered.prefix(160)); tree: \(diff.debugDescription)",
            file: file,
            line: line
        )
    }

    /// Choose the exact window through the native Window menu. Hittability
    /// alone does not reliably detect overlap, and keyboard cycling depends
    /// on the user's configured shortcut and window order.
    @MainActor
    private func bringForward(_ anchor: XCUIElement, in app: XCUIApplication, windowTitle: String = "Herdr Companion") {
        XCTAssertTrue(anchor.exists)
        app.activate()
        let windowMenu = app.menuBars.menuBarItems["Window"]
        windowMenu.click()
        // The main scene is listed as Herdr Companion, even when its document
        // title is PR Review. View also has a PR Review navigation command.
        let item = windowMenu.menuItems.matching(NSPredicate(
            format: "title == %@ OR label == %@", windowTitle, windowTitle
        )).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Window menu must offer \(windowTitle)")
        item.click()
    }

    // MARK: - Synthetic evidence

    private static func resolvedScreenshotDirectory() -> URL {
        let preferred = URL(fileURLWithPath: "/tmp/herdr-mac-goal-screens", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
            return preferred
        }

        let fallback = FileManager.default.temporaryDirectory.appending(path: "herdr-mac-goal-screens")
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    @MainActor
    private func saveWindowScreenshot(_ name: String, window: XCUIElement, directory: URL) {
        let screenshot = window.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(name).png"))

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The two synthetic active reviews `PRReviewDemo` publishes, without
/// importing the app module: UI tests only see them through identifiers,
/// titles, and rendered text.
private enum SyntheticReview {
    static let host = "demo"
    static let firstID = "prr_demo42"
    static let secondID = "prr_demo43"
    static let firstTitle = "Add seed catalog sync"
    static let secondTitle = "Tune watering reminders"
    static let firstDiff = "struct SeedCatalog {}"
    static let secondDiff = "struct ReminderSchedule {}"
    static let firstAdditionsSummary = "+84 −23"

    // Deleted-file fixtures appended to the first synthetic review by
    // `PRReviewDemo`, indexed after the seven original files.
    static let deletedSourcePath = "Sources/Legacy/SeedCatalogMigration.swift"
    static let deletedSourceSearchTerm = "SeedCatalogMigration.swift"
    static let deletedSourceSummary = "Deleted · 5 lines removed"
    static let deletedSourceRemovedLine = "struct SeedCatalogMigration {"
    static let deletedSourceQuestion = "Why remove this synthetic migration helper?"
    static let deletedProsePath = "Docs/Guides/seed-catalog-rollout.md"
    static let deletedProseSearchTerm = "seed-catalog-rollout.md"
    static let deletedProseSummary = "Deleted · 4 lines removed"
    static let deletedProseRemovedLine = "Retire this archived copy."
    static let deletedLongPath = "Sources/Legacy/Compatibility/SeedCatalogLegacyCompatibilityShimsAndMigrationHelpers.swift"
    static let deletedLongPathSummary = "Deleted · 2 lines removed"
    static let deletedLongPathRemovedLine = "enum SeedCatalogLegacyCompatibilityShims { static let enabled = false }"

    static func rowIdentifier(_ reviewID: String) -> String {
        "pr-review-review-\(reviewID)"
    }

    static func windowIdentifier(_ reviewID: String) -> String {
        "pr-review-window-\(host)|\(reviewID)"
    }

    static func popOutIdentifier(_ reviewID: String) -> String {
        "pr-review-pop-out-\(host)|\(reviewID)"
    }
}
