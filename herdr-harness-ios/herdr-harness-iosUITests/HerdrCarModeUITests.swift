import XCTest

/// Car mode on a real device hierarchy: four recent agents, oversized targets,
/// a voice-only detail screen, and no keyboard anywhere.
final class HerdrCarModeUITests: XCTestCase {
    @MainActor
    func testCarModeShowsFourAgentsWithLargeTargets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()

        let open = app.buttons["car-mode-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let exit = app.buttons["car-mode-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Car mode"].exists)

        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'car-card-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 4, "Car mode shows the four most relevant agents")

        let audio = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'car-audio-'")).firstMatch
        let reply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'car-reply-'")).firstMatch
        XCTAssertTrue(audio.exists)
        XCTAssertTrue(reply.exists)
        XCTAssertGreaterThanOrEqual(audio.frame.height, 60, "Summary audio must stay a driving-sized target")
        XCTAssertGreaterThanOrEqual(reply.frame.height, 60, "Reply must stay a driving-sized target")
        XCTAssertGreaterThanOrEqual(
            cards.firstMatch.frame.height,
            44,
            "Opening an agent must stay a comfortable target"
        )

        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/herdr-car-mode-grid.png"))
    }

    @MainActor
    func testCarModeDetailIsVoiceOnly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()

        let open = app.buttons["car-mode-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'car-card-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        // Prefer the demo agent whose answer is markdown-heavy, so the checks
        // below are looking at real blocks.
        let markdownCard = cards.containing(
            NSPredicate(format: "label CONTAINS 'Sample reading list export'")
        ).firstMatch
        (markdownCard.exists ? markdownCard : cards.firstMatch).tap()

        let mic = app.buttons["car-mic-cta"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(mic.frame.height, 90, "The voice reply target must stay oversized")
        XCTAssertTrue(app.staticTexts["Voice only — Car mode has no keyboard"].exists)

        // Answers arrive as markdown; Car mode must render it, never show the raw
        // markers. The demo fixture deliberately contains headings, bullets, a
        // table, a quote, and a fenced block.
        let visibleText = app.staticTexts.allElementsBoundByIndex.filter(\.isHittable).map(\.label)
        for marker in ["**", "##", "```", "| ---", "`"] {
            XCTAssertFalse(
                visibleText.contains { $0.contains(marker) },
                "Raw markdown marker \(marker) is visible in the detail view: \(visibleText)"
            )
        }
        XCTAssertTrue(
            visibleText.contains { $0.contains("What is in the export") },
            "The rendered markdown heading should be on screen: \(visibleText)"
        )

        // The whole point: nothing in Car mode asks you to type. The Agents tab
        // stays mounted behind the cover, so the check is scoped to the area
        // Car mode actually occupies, plus the absence of a keyboard.
        let overlappingFields = app.textFields.allElementsBoundByIndex.filter {
            $0.frame.intersects(mic.frame)
        }
        XCTAssertTrue(overlappingFields.isEmpty, "Car mode must not present a text field")
        XCTAssertEqual(app.keyboards.count, 0, "Car mode must never raise a keyboard")

        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/herdr-car-mode-detail.png"))

        let back = app.buttons["car-detail-back"]
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testCarModeCanBeLeftFromTheHeader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()

        let open = app.buttons["car-mode-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let exit = app.buttons["car-mode-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        exit.tap()

        XCTAssertTrue(open.waitForExistence(timeout: 5), "Leaving Car mode returns to the Agents tab")
        XCTAssertFalse(app.staticTexts["Car mode"].exists)
    }

    private func cards(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'car-card-'"))
    }
}
