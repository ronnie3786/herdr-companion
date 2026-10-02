import AppKit
import XCTest

/// Mac-only shell coverage: the menu bar and the detail-scope control that
/// replaced the iOS tab bar.
///
/// iOS had nothing to port here — a phone has no menu bar, and `AppTab` was a
/// `TabView`. These commands form part of the Mac shell contract, so they
/// get the same treatment the tab bar used to: assert they exist, are enabled in
/// demo mode, and actually move the detail column.
final class HerdrMacShellUITests: HerdrUITestCase {
    @MainActor
    func testPaneDeepLinkRecreatesClosedMainWindow() async throws {
        let app = launchDemoApp()
        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10),
            "The demo fleet should be loaded before closing the window"
        )

        let runningApplication = try XCTUnwrap(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle(for: Self.self).object(forInfoDictionaryKey: "HerdrTestedAppBundleIdentifier") as? String ?? "org.herdr.companion.macos"
            ).first(where: \.isActive),
            "The launched UI-test application should be the active Herdr process"
        )
        let originalProcessIdentifier = runningApplication.processIdentifier
        let applicationURL = try XCTUnwrap(runningApplication.bundleURL)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            app.shellWindow.waitForNonExistence(timeout: 5),
            "Closing Herdr's only window should leave no document window"
        )
        XCTAssertFalse(runningApplication.isTerminated, "Closing the window must keep Herdr running")

        let paneURL = try XCTUnwrap(URL(string: "herdr://pane/demo1%7Cw1%3Ap2"))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        let openedApplication: NSRunningApplication? = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSRunningApplication?, Error>) in
            NSWorkspace.shared.open(
                [paneURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: application)
                }
            }
        }

        XCTAssertEqual(openedApplication?.processIdentifier, originalProcessIdentifier)
        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w1:p2").waitForExistence(timeout: 10),
            "Opening a pane deep link should recreate the main window and route to that pane"
        )
        XCTAssertEqual(app.windows.count, 1, "The deep link should recreate exactly one main window")
    }

    @MainActor
    func testViewMenuMovesTheDetailScope() throws {
        let app = launchDemoApp()
        XCTAssertTrue(
            app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10),
            "The demo fleet should be loaded before driving the menus"
        )

        XCTAssertNil(app.menuBarItem("View", item: "Go to Attention"), "The Mac has no attention deck")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertNil(app.menuBarItem("View", item: "Workspace Overview"), "The Mac has no workspace overview")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        guard let fleet = app.menuBarItem("View", item: "Fleet") else {
            return XCTFail("View ▸ Fleet should exist")
        }
        XCTAssertTrue(fleet.isEnabled)
        fleet.click()

        XCTAssertTrue(
            app.control(identifier: "fleet-management-sheet").waitForExistence(timeout: 5),
            "View ▸ Fleet should show Fleet in the detail column"
        )
    }

    @MainActor
    func testNavigateMenuStepsThroughPanes() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10))

        guard let nextPane = app.menuBarItem("Navigate", item: "Next Pane") else {
            return XCTFail("Navigate ▸ Next Pane should exist")
        }
        XCTAssertTrue(nextPane.isEnabled)
        nextPane.click()

        // Nothing was selected, so the first pane in canonical fleet order wins.
        XCTAssertTrue(
            app.control(identifier: "terminal-demo2|w1:p1").waitForExistence(timeout: 5),
            "Next Pane should open a pane session in the detail column"
        )

        guard let previousPane = app.menuBarItem("Navigate", item: "Previous Pane") else {
            return XCTFail("Navigate ▸ Previous Pane should exist")
        }
        previousPane.click()
        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w3:p1").waitForExistence(timeout: 5),
            "Stepping back from the first pane should wrap to the last one"
        )
    }

    @MainActor
    func testFocusCommandsExposeDistinctKeyboardShortcuts() throws {
        let app = launchDemoApp()
        let pane = app.buttons["sidebar-pane-demo1|w1:p1"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()
        XCTAssertTrue(app.control(identifier: "terminal-demo1|w1:p1").waitForExistence(timeout: 5))

        guard let focus = app.menuBarItem("Navigate", item: "Focus Current Pane on Mac") else {
            return XCTFail("Navigate should expose Focus Current Pane on Mac")
        }
        XCTAssertTrue(focus.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        guard let focusAndZoom = app.menuBarItem("Navigate", item: "Focus Current Pane on Mac + Zoom") else {
            return XCTFail("Navigate should expose Focus Current Pane on Mac + Zoom")
        }
        XCTAssertTrue(focusAndZoom.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        app.typeKey("m", modifierFlags: [.command, .shift])
        let focusAndZoomToast = app.buttons["Focused + zoomed on Mac"]
        XCTAssertTrue(
            focusAndZoomToast.waitForExistence(timeout: 3),
            "⇧⌘M should focus and zoom the current pane"
        )
        focusAndZoomToast.click()

        app.typeKey("m", modifierFlags: [.command, .shift, .option])
        XCTAssertTrue(
            app.buttons["Focused on Mac"].waitForExistence(timeout: 3),
            "⌥⇧⌘M should focus the current pane"
        )
    }

    @MainActor
    func testCommandSevenReachesFleetFromTheKeyboard() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p2"].waitForExistence(timeout: 10))
        app.buttons["sidebar-pane-demo1|w1:p2"].click()
        XCTAssertTrue(app.control(identifier: "terminal-demo1|w1:p2").waitForExistence(timeout: 5))

        app.typeKey("7", modifierFlags: .command)

        XCTAssertTrue(
            app.control(identifier: "fleet-management-sheet").waitForExistence(timeout: 5),
            "⌘7 should reach Fleet without touching the menu"
        )
    }

    @MainActor
    func testCommandKSearchesAndOpensAChat() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)

        let palette = app.control(identifier: "command-palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "⌘K should present the global chat palette")
        let search = app.control(identifier: "command-palette-search")
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("reading")

        let result = app.control(identifier: "command-palette-row-demo1|w2:p1")
        XCTAssertTrue(result.waitForExistence(timeout: 3), "Pane-title search should find the matching chat")
        result.click()

        XCTAssertTrue(
            app.control(identifier: "terminal-demo1|w2:p1").waitForExistence(timeout: 5),
            "Opening a palette result should route through the normal pane session"
        )
        XCTAssertTrue(palette.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testCommandPaletteEscapeDismissesWithoutRouting() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p1"].waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        let palette = app.control(identifier: "command-palette")
        XCTAssertTrue(palette.waitForExistence(timeout: 5))

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertTrue(palette.waitForNonExistence(timeout: 3), "Escape should close the palette")
    }

    @MainActor
    func testFileMenuOffersNewWorkspaceInDemoMode() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 10))

        guard let newWorkspace = app.menuBarItem("File", item: "New Workspace") else {
            return XCTFail("File ▸ New Workspace should exist")
        }
        // Demo mode is controllable, so the command must not be greyed out.
        XCTAssertTrue(newWorkspace.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    @MainActor
    func testDetailToolbarExposesTheMoreMenu() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 10))

        XCTAssertTrue(
            app.control(identifier: "shell-more-menu").waitForExistence(timeout: 5),
            "The title bar should carry the ⋯ menu with the app's destinations"
        )
        XCTAssertFalse(
            app.control(identifier: "detail-scope-picker").exists,
            "The segmented scope picker was folded into the ⋯ menu"
        )
        XCTAssertTrue(
            app.shellWindow.exists,
            "The shell should run in a single document window"
        )
    }

    /// Fleet is a detail destination like every other, reached from the title
    /// bar's ⋯ menu rather than a second affordance of its own in the window chrome.
    @MainActor
    func testMoreMenuOpensFleetInTheDetailColumn() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 10))

        let menu = app.control(identifier: "shell-more-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10))

        XCTAssertFalse(
            app.control(identifier: "fleet-toolbar-button").exists,
            "Fleet lives in the ⋯ menu, so it must not also carry a dedicated toolbar button"
        )

        menu.click()
        guard let fleet = waitForFirst(
            of: [
                app.menuItems["shell-menu-fleet"],
                app.menuItems["Fleet"],
            ],
            timeout: 10
        ) else {
            return XCTFail("The ⋯ menu should offer Fleet")
        }
        fleet.click()

        XCTAssertTrue(
            app.control(identifier: "fleet-management-sheet").waitForExistence(timeout: 5),
            "Fleet should render in the detail column"
        )
        XCTAssertFalse(
            app.control(identifier: "fleet-close-button").exists,
            "A destination has nothing to dismiss, so it must not carry the sheet's Done button"
        )
    }

    /// The navigator used to carry an Active Work CTA above the tree. It lives
    /// in the title bar's ⋯ menu with the app's other destinations.
    @MainActor
    func testSidebarNoLongerCarriesTheActiveWorkCTA() throws {
        let app = launchDemoApp()
        XCTAssertTrue(app.buttons["sidebar-workspace-demo1|w1"].waitForExistence(timeout: 10))

        XCTAssertFalse(
            app.control(identifier: "sidebar-active-work").exists,
            "Active Work lives in the title bar's ⋯ menu, not the sidebar"
        )
    }

    @MainActor
    func testPaneHeaderExposesWorkingFolderButton() throws {
        let app = launchDemoApp()
        let pane = app.buttons["sidebar-pane-demo1|w1:p2"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))

        pane.click()

        XCTAssertTrue(
            app.buttons["pane-path-button"].waitForExistence(timeout: 5),
            "A selected pane should expose its working folder as a Finder button"
        )
    }
}
