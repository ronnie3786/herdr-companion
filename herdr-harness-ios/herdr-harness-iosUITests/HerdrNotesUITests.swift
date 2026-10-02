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
    func testEditorFormatsMarkdownAndKeepsDraftAfterFailedSave() {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()
        defer { app.terminate() }
        let notes = app.tabBars.buttons["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 8))
        notes.tap()
        app.buttons["notes-card-demo1|11111111-1111-1111-1111-111111111111"].tap()
        app.buttons["Edit"].tap()
        let editor = app.textViews["note-editor-body"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        editor.tap()
        editor.typeText("\n**Clear** *calm* ~~done~~ ")
        XCTAssertTrue((editor.value as? String ?? "").contains("Clear calm done"))
        XCTAssertFalse((editor.value as? String ?? "").contains("**Clear**"))
        app.buttons["note-format-underline"].tap()
        editor.typeText("Underlined")
        saveScreenshot("notes-editor", app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Couldn’t save your note.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("Underlined"))
        app.buttons["Cancel"].tap()
        app.buttons["Discard edits"].tap()
        XCTAssertTrue(app.staticTexts["note-full-body"].waitForExistence(timeout: 3))
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
