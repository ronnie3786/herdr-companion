import XCTest

/// Only synthetic snapshots and the demo transport enter these acceptance tests.
/// Fixture owners intentionally differ from the demo fleet: an unavailable route
/// must explain its original target instead of selecting a similarly named item.
final class HomeUITests: HerdrUITestCase {
    @MainActor
    func testGlobalTabsKeepTheirOrderAndCommandShortcuts() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        let tabs = ["home", "reviews", "watchers", "chats"].map {
            app.control(identifier: "home-tab-\($0)")
        }
        for tab in tabs {
            XCTAssertTrue(tab.exists)
            XCTAssertTrue(tab.isHittable)
        }
        for (left, right) in zip(tabs, tabs.dropFirst()) {
            XCTAssertLessThan(left.frame.maxX, right.frame.minX + 1)
        }
        XCTAssertFalse(app.control(identifier: "sidebar-pane-demo1|w1:p1").exists)
        assertSelected(tabs[0])

        for (key, tab, destination) in [
            ("2", "reviews", "pr-review-sidebar"),
            ("3", "watchers", "watchers-destination"),
            ("4", "chats", "sidebar-pane-demo1|w1:p1"),
            ("1", "home", "home.content"),
        ] {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(app.control(identifier: destination).waitForExistence(timeout: 10))
            assertSelected(app.control(identifier: "home-tab-\(tab)"))
            XCTAssertEqual(app.windows.count, 1, "Changing a global tab should reuse the main window")
        }
        saveAccessibilitySnapshot("home-global-navigation", app: app)
    }

    @MainActor
    func testSearchFiltersHomeAndEscapeRestoresTheUnfilteredFocus() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        XCTAssertTrue(app.control(identifier: "home.focus.docs.open").exists)
        app.typeKey("f", modifierFlags: .command)
        let search = app.control(identifier: "home-search-field")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeText("Passkey")
        XCTAssertTrue(app.control(identifier: "home.focus.passkey.open").waitForExistence(timeout: 5))
        XCTAssertFalse(app.control(identifier: "home.focus.docs.open").exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-synthetic-home-item-matches-this")
        XCTAssertTrue(app.control(identifier: "home.focus.card").waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.control(identifier: "home.allClear").exists,
                       "A search with no matches must not claim the fleet is all clear")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.control(identifier: "home.focus.docs.open").waitForExistence(timeout: 5))
    }

    @MainActor
    func testEscapeClosesSearchBeforeTheOpenChatTray() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        app.typeKey("j", modifierFlags: .command)
        let tray = app.control(identifier: "home-chat-tray")
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        let search = app.control(identifier: "home-search-field")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Docs")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(tray.exists, "The first Escape belongs to Home search")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5), "The second Escape dismisses the tray")
        XCTAssertTrue(app.control(identifier: "home-ask-bar").isHittable)
    }

    @MainActor
    func testCommandFFocusesTheSelectedDestinationsOwnSearchField() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        for (shortcut, field) in [
            ("2", app.control(identifier: "pr-review-search")),
            ("3", app.textFields["Find a watcher"]),
            ("4", app.textFields["Filter chats"]),
        ] {
            app.typeKey(shortcut, modifierFlags: .command)
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            app.typeKey("f", modifierFlags: .command)
            // Typing through the app, without clicking the field, proves focus.
            app.typeText("synthetic-local-filter")
            XCTAssertTrue(waitForHomeValue("synthetic-local-filter", in: field))
            XCTAssertFalse(app.control(identifier: "home-search-field").exists)
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
        }
    }

    @MainActor
    func testSkipSnoozeUndoAndRadarDismissalRemainLocal() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        let homeTab = app.control(identifier: "home-tab-home")
        XCTAssertEqual(homeTab.value as? String, "5 need attention")
        app.control(identifier: "home.focus.skip").click()
        let later = app.control(identifier: "home.focus.passkey.later")
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        XCTAssertEqual(homeTab.value as? String, "5 need attention", "Skip changes order, not unresolved count")
        later.click()
        XCTAssertTrue(later.waitForNonExistence(timeout: 5))
        XCTAssertEqual(homeTab.value as? String, "5 need attention", "Snoozed work is still unresolved")
        let undo = app.control(identifier: "home-snooze-undo")
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.click()
        XCTAssertTrue(later.waitForExistence(timeout: 5), "Undo restores the snoozed card and selection")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        app.control(identifier: "home.radar.crash.dismiss").click()
        XCTAssertTrue(app.control(identifier: "home.radar.crash.dismiss").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.control(identifier: "home.radar.storage.open").exists)
        XCTAssertEqual(homeTab.value as? String, "5 need attention")
        XCTAssertFalse(app.control(identifier: "home.allClear").exists)
    }

    @MainActor
    func testRecapExpandsWithoutNavigatingAndKeepsItsStateAcrossTabs() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        let disclosure = revealHomeControl("home.recap.disclosure", in: app)
        XCTAssertTrue(waitForHomeValue("Collapsed", in: disclosure))
        disclosure.click()
        XCTAssertTrue(waitForHomeValue("Expanded", in: disclosure))
        XCTAssertTrue(app.control(identifier: "home.recap.row.recap-0").waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.control(identifier: "watchers-destination").waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.control(identifier: "home.content").waitForExistence(timeout: 5))
        let restored = revealHomeControl("home.recap.disclosure", in: app)
        XCTAssertTrue(waitForHomeValue("Expanded", in: restored))
        restored.click()
        XCTAssertTrue(app.control(identifier: "home.recap.row.recap-0").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testAskContextAndDraftSurviveClosingAndMovingToFirstMate() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        let mainWindow = app.shellWindow
        app.control(identifier: "home.focus.ask").click()
        let tray = mainWindow.descendant(identifier: "home-chat-tray")
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        let context = tray.descendant(identifier: "home-chat-context")
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertTrue(context.descendantText(containing: "Docs search").exists)
        let editor = tray.descendant(identifier: "composer-draft-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForHomeValue("Tell me about Docs search.", in: editor))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Keep this synthetic draft")
        editor.typeKey(.return, modifierFlags: .shift)
        editor.typeText("and this second line.")
        let draft = "Keep this synthetic draft\nand this second line."
        XCTAssertTrue(waitForHomeValue(draft, in: editor))
        tray.descendantButton(titled: "Close Home chat").click()
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5))
        app.typeKey("j", modifierFlags: .command)
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHomeValue(draft, in: editor))
        XCTAssertTrue(context.exists)
        tray.descendant(identifier: "home-chat-popout").click()
        let firstMate = app.window(titled: "First Mate")
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10))
        let transferredEditor = firstMate.descendant(identifier: "composer-draft-editor")
        XCTAssertTrue(transferredEditor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForHomeValue(draft, in: transferredEditor), "Pop out must carry the exact multiline draft")
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 2, "Pop out opens the existing single First Mate window")
        saveAccessibilitySnapshot("home-chat-transferred", app: app)
    }

    @MainActor
    func testUnavailableRoutesRetainTheirExactFixtureOwner() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        let mainWindow = app.shellWindow
        app.control(identifier: "home.focus.docs.open").click()
        let firstMate = app.window(titled: "First Mate")
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10))
        XCTAssertTrue(firstMate.descendantText(containing: "Conversation unavailable").waitForExistence(timeout: 5))
        XCTAssertTrue(firstMate.descendantText(containing: "docs on fixture-dev is unavailable").exists,
                      "The unavailable conversation must retain both its requested feature and machine")
        XCTAssertFalse(firstMate.descendant(identifier: "composer-draft-editor").exists,
                       "A missing exact owner must not expose a composer for another conversation")
        XCTAssertTrue(mainWindow.descendant(identifier: "home.content").exists)
        XCTAssertEqual(app.windows.count, 2, "The exact route should reuse the dedicated First Mate window")
        firstMate.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(firstMate.waitForNonExistence(timeout: 5))
        mainWindow.descendant(identifier: "home.radar.crash.open").click()
        XCTAssertTrue(app.control(identifier: "watchers-destination").waitForExistence(timeout: 5))
        let missing = app.text(containing: "Watcher crash is unavailable on the requested machine, fixture-dev")
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.control(identifier: "home.content").waitForExistence(timeout: 5))
        app.control(identifier: "home.radar.storage.open").click()
        let machineNotice = app.control(identifier: "settings-machine-reveal-notice")
        XCTAssertTrue(machineNotice.waitForExistence(timeout: 5))
        XCTAssertTrue(machineNotice.label.contains("fixture-dev")
                      || (machineNotice.value as? String)?.contains("fixture-dev") == true
                      || machineNotice.descendantText(containing: "fixture-dev").exists)
    }

    @MainActor
    func testEachSyntheticMomentRetainsItsHonestAvailability() {
        for (moment, greeting, notice) in [
            ("morning", "Good morning.", ""),
            ("afternoon", "Good afternoon.", ""),
            ("clear", "Good evening.", ""),
            ("trouble", "Heads up.", ""),
            ("loading", "Welcome home.", ""),
            ("disconnected", "Let’s reconnect.", "Current work may be missing"),
            ("stale", "Here’s the last update.", "last known state"),
        ] {
            let app = launchHomeDemoApp(moment: moment)
            XCTAssertTrue(app.text(containing: greeting).waitForExistence(timeout: 5))
            XCTAssertTrue(app.control(identifier: "home-ask-bar").exists)
            XCTAssertTrue(app.control(identifier: "home.firstMate.face").exists)
            XCTAssertTrue(app.control(identifier: "home.firstMate.window").exists)
            if !notice.isEmpty { XCTAssertTrue(app.text(containing: notice).exists) }
            if ["loading", "disconnected", "stale"].contains(moment) {
                XCTAssertFalse(app.control(identifier: "home.allClear").exists)
            }
            if moment == "loading" { XCTAssertFalse(app.control(identifier: "home.focus.card").exists) }
            if moment == "clear" {
                XCTAssertEqual(app.control(identifier: "home-tab-home").value as? String, "")
                XCTAssertFalse(app.control(identifier: "home.focus.plan.later").exists,
                               "An optional idea is not unresolved work to snooze")
            }
            saveAccessibilitySnapshot("home-\(moment)", app: app)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "home-\(moment)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testNativeWindowControlsDragResizeAndFullScreenRemainAvailable() {
        let app = launchHomeDemoApp()
        defer { app.terminate() }
        let window = app.shellWindow
        for identifier in [XCUIIdentifierCloseWindow, XCUIIdentifierMinimizeWindow] {
            XCTAssertTrue(window.buttons[identifier].exists)
            XCTAssertTrue(window.buttons[identifier].isEnabled)
        }
        XCTAssertNotNil(waitForFirst(of: [window.buttons[XCUIIdentifierFullScreenWindow],
                                          window.buttons[XCUIIdentifierZoomWindow]]))

        let original = window.frame
        let titlebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 135, dy: 16))
        titlebar.click(forDuration: 0.3, thenDragTo: titlebar.withOffset(CGVector(dx: 45, dy: 35)))
        XCTAssertTrue(waitForWindow(window) { frame in
            abs(frame.minX - original.minX) > 4 || abs(frame.minY - original.minY) > 4
        }, "The empty titlebar region should move the native window")

        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.click(forDuration: 0.4, thenDragTo: corner.withOffset(CGVector(dx: -900, dy: -600)))
        XCTAssertGreaterThanOrEqual(window.frame.width, 995)
        XCTAssertGreaterThanOrEqual(window.frame.height, 675)
        XCTAssertLessThanOrEqual(window.frame.width, 1005)
        XCTAssertLessThanOrEqual(window.frame.height, 685)
        for identifier in ["home-tab-home", "home-tab-reviews", "home-tab-watchers", "home-tab-chats",
                           "home-search-button", "home-ask-bar", "home.focus.ask"] {
            XCTAssertTrue(app.control(identifier: identifier).isHittable, "\(identifier) should fit at minimum size")
        }
        let small = window.frame
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(waitForWindow(window) { $0.width > small.width + 30 }, "Full screen should expand the native window")
        XCTAssertTrue(app.control(identifier: "home-ask-bar").isHittable)
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(waitForWindow(window) { abs($0.width - small.width) < 10 })
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.control(identifier: "home.content").waitForExistence(timeout: 10),
                       "The Home command should recreate a closed main window")
    }

    @MainActor
    private func assertSelected(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == YES"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    private func waitForWindow(_ window: XCUIElement, matches: @escaping (CGRect) -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in matches(window.frame) }, object: window)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }
}
