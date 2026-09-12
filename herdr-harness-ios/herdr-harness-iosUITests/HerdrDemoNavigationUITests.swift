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
    func testFullScreenPaneModesAndExpandableControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()

        let workspace = app.buttons["Garden Planner, Needs you, 3 panes"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8), "The workspace switcher should appear in demo mode")
        workspace.tap()

        let blockedPane = app.buttons["Choose sample garden colors, Claude, Needs you"]
        XCTAssertTrue(blockedPane.waitForExistence(timeout: 3))
        blockedPane.tap()

        XCTAssertTrue(app.buttons["pane-session-title"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["pane-session-scope"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.textFields["prompt-composer"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Pane detail should hide the app tab bar")

        let chatMode = app.buttons["pane-mode-chat"]
        let gitMode = app.buttons["pane-mode-git"]
        let terminalMode = app.buttons["pane-mode-terminal"]
        for mode in [chatMode, gitMode, terminalMode] {
            XCTAssertTrue(mode.waitForExistence(timeout: 3))
        }
        XCTAssertEqual(chatMode.frame.width, gitMode.frame.width, accuracy: 1)
        XCTAssertEqual(gitMode.frame.width, terminalMode.frame.width, accuracy: 1)
        XCTAssertLessThan(chatMode.frame.minX, gitMode.frame.minX)
        XCTAssertLessThan(gitMode.frame.minX, terminalMode.frame.minX)
        XCTAssertFalse(chatMode.isEnabled, "The nonsemantic Claude demo pane must not expose native Chat")
        XCTAssertEqual(terminalMode.value as? String, "Selected")
        XCTAssertFalse(app.buttons["Yes, proceed"].exists, "Canned response chips should not consume pane space")

        for key in ["up", "down", "tab", "enter"] {
            XCTAssertTrue(app.buttons["terminal-key-\(key)"].exists)
        }
        XCTAssertFalse(app.buttons["terminal-key-left"].exists)
        try saveScreenshot("01-terminal-collapsed", app: app)

        app.buttons["terminal-controls-toggle"].tap()
        XCTAssertTrue(app.buttons["terminal-key-left"].waitForExistence(timeout: 2))
        for key in ["left", "right", "escape", "backspace"] {
            XCTAssertTrue(app.buttons["terminal-key-\(key)"].exists)
        }
        try saveScreenshot("02-terminal-expanded", app: app)

        let composer = app.textFields["prompt-composer"]
        composer.tap()
        composer.typeText("draft survives pane modes")

        try selectPaneMode("Git", app: app)
        XCTAssertTrue(app.staticTexts["staged"].waitForExistence(timeout: 3))
        try saveScreenshot("03-git-status", app: app)

        let diffButton = app.buttons["View diff for Sources/Garden/GardenCanvas.swift"]
        XCTAssertTrue(diffButton.waitForExistence(timeout: 2))
        diffButton.tap()
        XCTAssertTrue(app.navigationBars["Sources/Garden/GardenCanvas.swift"].waitForExistence(timeout: 3))
        try saveScreenshot("04-git-diff", app: app)
        app.buttons["Done"].tap()

        try selectPaneActionMode("Skills", app: app)
        XCTAssertTrue(app.staticTexts["workspace skills"].waitForExistence(timeout: 3))
        try saveScreenshot("05-skills", app: app)

        try selectPaneMode("Terminal", app: app)
        let restoredComposer = app.textFields["prompt-composer"]
        XCTAssertTrue(restoredComposer.waitForExistence(timeout: 3))
        XCTAssertEqual(restoredComposer.value as? String, "draft survives pane modes")
        app.buttons["terminal-controls-toggle"].tap()
        XCTAssertTrue(app.buttons["Insert a workspace file path"].waitForExistence(timeout: 2))

        app.buttons["Insert a workspace file path"].tap()
        let fileSearch = app.textFields["Search project files"]
        XCTAssertTrue(fileSearch.waitForExistence(timeout: 3))
        fileSearch.tap()
        fileSearch.typeText("Garden")
        XCTAssertTrue(app.buttons["Insert Sources/Garden/GardenCanvas.swift"].waitForExistence(timeout: 3))
        try saveScreenshot("06-file-search", app: app)
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["Insert Jira ticket context"].waitForExistence(timeout: 3))
        app.buttons["Insert Jira ticket context"].tap()
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
    func testPlainShellKeepsThreeModesAndDisablesChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()

        let workspace = app.buttons["Garden Planner, Needs you, 3 panes"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8))
        workspace.tap()

        let shellPane = app.buttons["Unit tests, Terminal, Shell"]
        XCTAssertTrue(shellPane.waitForExistence(timeout: 3))
        shellPane.tap()

        let chatMode = app.buttons["pane-mode-chat"]
        let terminalMode = app.buttons["pane-mode-terminal"]
        XCTAssertTrue(chatMode.waitForExistence(timeout: 3))
        XCTAssertFalse(chatMode.isEnabled)
        XCTAssertEqual(terminalMode.value as? String, "Selected")
        XCTAssertFalse(app.descendants(matching: .any)["pi-context-meter"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pi-chat-model"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["pi-chat-thinking"].exists)
    }

    @MainActor
    func testVoiceActionsRemainReachableInLandscapeAccessibilityText() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = [
            "-HerdrDemoMode",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        let workspace = app.buttons["Garden Planner, Needs you, 3 panes"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8))
        workspace.tap()

        let blockedPane = app.buttons["Choose sample garden colors, Claude, Needs you"]
        XCTAssertTrue(blockedPane.waitForExistence(timeout: 3))
        blockedPane.tap()

        let controls = app.buttons["terminal-controls-toggle"]
        XCTAssertTrue(controls.waitForExistence(timeout: 3))
        controls.tap()

        let voice = app.buttons["composer-record-voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        voice.tap()

        XCTAssertTrue(app.navigationBars["VOICE NOTE"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Start recording"].isHittable)
        XCTAssertTrue(app.buttons["Close"].isHittable)
        XCTAssertTrue(app.buttons["Attach audio without transcribing"].exists)
        XCTAssertTrue(app.buttons["Transcribe"].exists)
    }

    @MainActor
    private func selectPaneMode(_ mode: String, app: XCUIApplication) throws {
        let modeButton = app.buttons["pane-mode-\(mode.lowercased())"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 3), "The pane mode bar should expose \(mode)")
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: modeButton)
        waitForExpectations(timeout: 3)
        modeButton.tap()
    }

    @MainActor
    private func selectPaneActionMode(_ mode: String, app: XCUIApplication) throws {
        let menu = app.buttons["Pane actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let modeButton = app.buttons["\(mode) view"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 2), "Pane actions should keep \(mode) reachable")
        modeButton.tap()
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
