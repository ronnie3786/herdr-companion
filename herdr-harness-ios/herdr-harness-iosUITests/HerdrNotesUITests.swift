import XCTest

final class HerdrNotesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNotesCanBeFoundReadAndSearched() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()
        defer { app.terminate() }

        let notesTab = app.tabBars.buttons["Notes"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 8))
        notesTab.tap()

        let releaseNote = app.buttons["notes-card-demo1|11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(releaseNote.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notes-machine-picker"].exists)
        saveScreenshot("notes-list", app: app)
        releaseNote.tap()

        let body = app.staticTexts["note-full-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        XCTAssertTrue(body.label.contains("Review the new HUD bubbles."))
        XCTAssertTrue(app.staticTexts["Sample release checklist"].exists)
        saveScreenshot("notes-detail", app: app)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let search = app.searchFields["Search notes"]
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("release checklist")
        XCTAssertTrue(releaseNote.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Sample weekend ideas"].exists)
        saveScreenshot("notes-search", app: app)
    }

    @MainActor
    func testNotesRemainReadableWithLargeText() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HerdrDemoMode",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()
        defer { app.terminate() }
        let notesTab = app.tabBars.buttons["Notes"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 8))
        notesTab.tap()
        let note = app.buttons["notes-card-demo1|11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        if !note.isHittable { app.swipeUp() }
        note.tap()
        let body = app.staticTexts["note-full-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        if !body.isHittable { app.swipeUp() }
        XCTAssertTrue(body.isHittable)
        saveScreenshot("notes-large-text", app: app)
    }

    @MainActor
    private func saveScreenshot(_ name: String, app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/herdr-notes-ui-screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(name).png"))
    }
}
