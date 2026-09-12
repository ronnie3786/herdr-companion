import XCTest

final class HerdrDemoNavigationUITests: XCTestCase {
    private let screenshotDirectory = URL(fileURLWithPath: "/tmp/herdr-ios-goal-screens", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(
            at: screenshotDirectory,
            withIntermediateDirectories: true
        )
    }

    @MainActor
    func testPaneModesLiveInMenuAndTerminalKeysAreOptIn() throws {
        let app = launchDemoPane(paneID: "demo1|w1:p2")

        XCTAssertTrue(app.buttons["pane-session-title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pane-session-scope"].exists)
        XCTAssertTrue(app.textFields["prompt-composer"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Pane detail should hide the app tab bar")
        XCTAssertFalse(app.descendants(matching: .any)["pane-mode-bar"].exists)
        for mode in ["chat", "git", "terminal"] {
            XCTAssertFalse(app.buttons["pane-mode-\(mode)"].exists, "Modes must not consume a separate row")
        }
        XCTAssertFalse(app.buttons["Yes, proceed"].exists)
        XCTAssertTrue(app.buttons["composer-record-voice"].exists)
        XCTAssertTrue(app.buttons["composer-attach"].exists)
        assertTerminalKeysHidden(app)
        try saveScreenshot("01-compact-composer", app: app)

        let paneMenu = app.descendants(matching: .any)["pane-mode-toggle"]
        XCTAssertEqual(paneMenu.value as? String, "Terminal view")
        paneMenu.tap()
        let chat = app.buttons["pane-action-mode-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 3))
        XCTAssertFalse(chat.isEnabled, "A nonsemantic pane must not acquire native Chat support")
        let terminal = app.buttons["pane-action-mode-terminal"]
        XCTAssertEqual(terminal.label, "Terminal view, selected")
        XCTAssertTrue(app.buttons["pane-action-mode-git"].isEnabled)
        XCTAssertTrue(app.buttons["pane-action-mode-skills"].isEnabled)
        terminal.tap()

        openPromptTools(app)
        assertTerminalKeysHidden(app)
        let keysToggle = app.descendants(matching: .any)["composer-terminal-keys-toggle"]
        XCTAssertTrue(keysToggle.waitForExistence(timeout: 3))
        keysToggle.tap()
        for key in ["up", "down", "tab", "enter", "left", "right", "escape", "backspace"] {
            XCTAssertTrue(app.buttons["terminal-key-\(key)"].waitForExistence(timeout: 3))
        }
        try saveScreenshot("02-opt-in-terminal-keys", app: app)
        openPromptTools(app)
        app.descendants(matching: .any)["composer-terminal-keys-toggle"].tap()
        assertTerminalKeysHidden(app)

        let composer = app.textFields["prompt-composer"]
        composer.tap()
        composer.typeText("draft survives pane modes")

        selectPaneMode("Git", app: app)
        XCTAssertTrue(app.staticTexts["staged"].waitForExistence(timeout: 3))
        try saveScreenshot("03-git-status", app: app)

        let diffButton = app.buttons["View diff for Sources/Garden/GardenCanvas.swift"]
        XCTAssertTrue(diffButton.waitForExistence(timeout: 2))
        diffButton.tap()
        XCTAssertTrue(app.navigationBars["Sources/Garden/GardenCanvas.swift"].waitForExistence(timeout: 3))
        try saveScreenshot("04-git-diff", app: app)
        app.buttons["Done"].tap()

        selectPaneMode("Skills", app: app)
        XCTAssertTrue(app.staticTexts["workspace skills"].waitForExistence(timeout: 3))
        try saveScreenshot("05-skills", app: app)

        selectPaneMode("Terminal", app: app)
        let restoredComposer = app.textFields["prompt-composer"]
        XCTAssertTrue(restoredComposer.waitForExistence(timeout: 3))
        XCTAssertEqual(restoredComposer.value as? String, "draft survives pane modes")
        assertTerminalKeysHidden(app)

        openPromptTools(app)
        let files = app.buttons["composer-workspace-file"]
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        files.tap()
        let fileSearch = app.textFields["Search project files"]
        XCTAssertTrue(fileSearch.waitForExistence(timeout: 3))
        fileSearch.tap()
        fileSearch.typeText("Garden")
        XCTAssertTrue(app.buttons["Insert Sources/Garden/GardenCanvas.swift"].waitForExistence(timeout: 3))
        try saveScreenshot("06-file-search", app: app)
        app.buttons["Done"].tap()

        openPromptTools(app)
        let jira = app.buttons["composer-jira"]
        XCTAssertTrue(jira.waitForExistence(timeout: 3))
        jira.tap()
        XCTAssertTrue(app.navigationBars["JIRA CONTEXT"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["TASK-101"].waitForExistence(timeout: 3))
        try saveScreenshot("07-jira-context", app: app)
        app.buttons["Done"].tap()

        let voice = app.buttons["composer-record-voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Record a voice note")).count, 1)
        voice.tap()
        XCTAssertTrue(app.navigationBars["VOICE NOTE"].waitForExistence(timeout: 3))
        try saveScreenshot("08-voice-note", app: app)
        app.buttons["Close"].tap()
    }

    @MainActor
    func testPlainShellKeepsMenuModesAndHidesPiControls() throws {
        let app = launchDemoPane(paneID: "demo1|w1:p3")
        let menu = app.descendants(matching: .any)["pane-mode-toggle"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertEqual(menu.value as? String, "Terminal view")
        XCTAssertFalse(app.descendants(matching: .any)["pane-mode-bar"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pi-context-meter"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pi-chat-model"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pi-chat-thinking"].exists)
        assertTerminalKeysHidden(app)

        menu.tap()
        let chat = app.buttons["pane-action-mode-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 3))
        XCTAssertFalse(chat.isEnabled)
        XCTAssertEqual(app.buttons["pane-action-mode-terminal"].label, "Terminal view, selected")
        XCTAssertTrue(app.buttons["pane-action-mode-git"].exists)
        XCTAssertTrue(app.buttons["pane-action-mode-skills"].exists)
    }

    @MainActor
    func testVoiceActionsRemainReachableInLandscapeAccessibilityText() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = launchDemoPane(
            paneID: "demo1|w1:p2",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            ]
        )
        XCTAssertFalse(app.descendants(matching: .any)["pane-mode-bar"].exists)
        assertTerminalKeysHidden(app)
        let voice = app.buttons["composer-record-voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        XCTAssertTrue(voice.isHittable)
        voice.tap()

        XCTAssertTrue(app.navigationBars["VOICE NOTE"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Start recording"].isHittable)
        XCTAssertTrue(app.buttons["Close"].isHittable)
        XCTAssertTrue(app.buttons["Attach audio without transcribing"].exists)
        XCTAssertTrue(app.buttons["Transcribe"].exists)
    }

    @MainActor
    private func launchDemoPane(paneID: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"] + extraArguments
        app.launch()
        let navigator = app.buttons["sidebar-toggle"]
        XCTAssertTrue(navigator.waitForExistence(timeout: 8))
        navigator.tap()
        let pane = app.buttons["sidebar-pane-\(paneID)"]
        let sidebar = app.scrollViews["herdr-sidebar"]
        for _ in 0..<12 {
            if pane.exists, sidebar.frame.contains(CGPoint(x: pane.frame.midX, y: pane.frame.midY)) { break }
            sidebar.swipeUp()
        }
        XCTAssertTrue(pane.waitForExistence(timeout: 3))
        pane.tap()
        return app
    }

    @MainActor
    private func assertTerminalKeysHidden(_ app: XCUIApplication) {
        for key in ["up", "down", "tab", "enter", "left", "right", "escape", "backspace"] {
            XCTAssertFalse(app.buttons["terminal-key-\(key)"].exists, "Terminal keys are mounted only after opting in")
        }
    }

    @MainActor
    private func openPromptTools(_ app: XCUIApplication) {
        let more = app.descendants(matching: .any)["composer-more-tools"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
    }

    @MainActor
    private func selectPaneMode(_ mode: String, app: XCUIApplication) {
        let menu = app.descendants(matching: .any)["pane-mode-toggle"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let choice = app.buttons["pane-action-mode-\(mode.lowercased())"]
        XCTAssertTrue(choice.waitForExistence(timeout: 3), "Pane actions should keep \(mode) reachable")
        XCTAssertTrue(choice.isEnabled)
        choice.tap()
    }

    @MainActor
    private func saveScreenshot(_ name: String, app: XCUIApplication) throws {
        let screenshot = app.screenshot()
        try screenshot.pngRepresentation.write(to: screenshotDirectory.appending(path: "\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
