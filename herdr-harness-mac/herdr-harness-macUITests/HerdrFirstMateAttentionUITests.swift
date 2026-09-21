import XCTest

/// The Chat navigator's First Mate attention badge, driven end-to-end by the
/// existing synthetic demo.
///
/// The fleet-index suite proves the status predicate and polling; this suite
/// proves the shipped Mac UI surfaces that count from Chat without opening
/// First Mate, never clears it just by visiting, and keeps it accurate across
/// the demo's Working and Human checkpoint scenarios.
final class HerdrFirstMateAttentionUITests: HerdrUITestCase {
    private let screenshotDirectory = HerdrFirstMateAttentionUITests.resolvedScreenshotDirectory()

    @MainActor
    func testAttentionBadgeTracksDemoScenariosFromChat() throws {
        let app = launchDemoApp()
        let firstMate = app.buttons["open-first-mate"]
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10), "The Chat navigator should list First Mate")

        // The demo opens on Planning, which waits on the human: attention is
        // visible from Chat before First Mate has ever been opened.
        XCTAssertTrue(
            waitForValue("1 feature waiting on your direction", of: firstMate),
            "Waiting work should badge First Mate without opening it"
        )
        saveScreenshot("first-mate-attention-chat", app: app, directory: screenshotDirectory)

        // Opening and returning must not acknowledge or clear the reminder.
        firstMate.click()
        let next = app.buttons["first-mate-demo-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "The demo sidebar should expose Next scenario")
        saveScreenshot("first-mate-attention-open", app: app, directory: screenshotDirectory)
        app.buttons["first-mate-back"].click()
        XCTAssertTrue(firstMate.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue("1 feature waiting on your direction", of: firstMate),
            "Visiting First Mate must not clear outstanding attention"
        )

        // Implementation is working: working features do not contribute.
        firstMate.click()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.click()
        app.buttons["first-mate-back"].click()
        XCTAssertTrue(firstMate.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue("No features waiting on your direction", of: firstMate),
            "A working feature should clear the badge"
        )
        saveScreenshot("first-mate-attention-cleared", app: app, directory: screenshotDirectory)

        // Seven reviewers is still working; the Human checkpoint waits again.
        firstMate.click()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.click()
        next.click()
        app.buttons["first-mate-back"].click()
        XCTAssertTrue(firstMate.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue("1 feature waiting on your direction", of: firstMate),
            "A human checkpoint should restore the badge"
        )
        saveScreenshot("first-mate-attention-returned", app: app, directory: screenshotDirectory)
    }

    @MainActor
    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Mirrors the other Mac suites: prefer `/tmp` when the runner can write
    /// there, and fall back to the runner's container. `XCTAttachment` carries
    /// the same screenshots into the test report either way.
    private static func resolvedScreenshotDirectory() -> URL {
        let preferred = URL(fileURLWithPath: "/tmp/herdr-first-mate-attention-screens", isDirectory: true)
        let fileManager = FileManager.default
        if (try? fileManager.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
            return preferred
        }

        let fallback = fileManager.temporaryDirectory.appending(path: "herdr-first-mate-attention-screens")
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}
