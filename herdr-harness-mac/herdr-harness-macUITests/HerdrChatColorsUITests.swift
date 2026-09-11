import XCTest

final class HerdrChatColorsUITests: HerdrUITestCase {
    @MainActor
    func testColorInheritanceFilteringInlineRenameAndRemoval() throws {
        let app = launchDemoApp()
        defer { app.terminate() }
        let first = app.buttons["sidebar-pane-demo1|w1:p1"]
        let sibling = app.buttons["sidebar-pane-demo1|w1:p2"]
        let other = app.buttons["sidebar-pane-demo1|w2:p1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))

        app.control(identifier: "sidebar-recent-filter").click()
        app.menuItems["Recents"].click()
        first.rightClick()
        app.menuItems["Tab color"].hover()
        let lavender = app.menuItems["tab-color-lavender"]
        XCTAssertTrue(lavender.waitForExistence(timeout: 3))
        lavender.click()

        let label = app.buttons["chat-color-label-lavender"]
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertTrue(sibling.label.contains("Lavender"), "Every sibling inherits the tab color")
        label.click()
        XCTAssertTrue(first.exists)
        XCTAssertTrue(sibling.exists)
        XCTAssertTrue(other.waitForNonExistence(timeout: 3))
        XCTAssertEqual(label.value as? String, "Selected")

        app.buttons["chat-color-rename-lavender"].click()
        let input = app.textFields["chat-color-label-input-lavender"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        // Send to the current responder, not the text-field element: element
        // typing can focus it implicitly and mask the pencil's focus regression.
        app.typeText("GARDEN-42 Irrigation")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertTrue(label.label.contains("GARDEN-42 Irrigation"))
        XCTAssertTrue(other.waitForNonExistence(timeout: 3), "Renaming must preserve the active filter")

        app.buttons["chat-color-rename-lavender"].click()
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        app.typeText("Discard this edit")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(label.label.contains("GARDEN-42 Irrigation"))
        label.click()
        XCTAssertTrue(other.waitForExistence(timeout: 3), "Click again clears the filter")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Muted chat colors in Recents"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
        app.launch()
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        XCTAssertTrue(label.label.contains("GARDEN-42 Irrigation"), "Color labels persist across relaunches")
        first.rightClick()
        app.menuItems["Tab color"].hover()
        let remove = app.menuItems["tab-color-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.click()
        XCTAssertTrue(label.waitForNonExistence(timeout: 3), "Removing the last assignment hides its legend entry")
        XCTAssertFalse(sibling.label.contains("color group:"))
    }
}
