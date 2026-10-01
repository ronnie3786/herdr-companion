import XCTest
import UIKit

/// The iPad First Mates layout end to end in the demo: the inspector toggle,
/// the folding list, Git from the chat bar and from a Workflow commit.
@MainActor
final class HerdrFirstMateIPadA2UITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testInspectorListAndGitFromTheChatBarAndWorkflow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Dedicated iPad acceptance") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 10)); receipt.tap()

        // Landscape opens with the inspector docked; the trailing button hides it.
        let info = app.otherElements["first-mate-info-column"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        let toggle = app.buttons["first-mate-chat-inspector-toggle"]
        let git = app.buttons["first-mate-chat-git"], more = app.buttons["first-mate-feature-options"]
        XCTAssertLessThan(git.frame.maxX, more.frame.minX + 1)
        XCTAssertLessThan(more.frame.maxX, toggle.frame.minX + 1)
        try capture("a2-live-landscape", app)
        toggle.tap()
        XCTAssertTrue(info.waitForNonExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(info.waitForExistence(timeout: 5))

        // The list folds into the rail and comes back.
        app.buttons["first-mate-chat-list-toggle"].tap()
        XCTAssertTrue(app.buttons["first-mate-rail-lead"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["first-mate-rail-demo1-demo-receipts"].exists)
        try capture("a2-live-rail", app)
        app.buttons["first-mate-chat-list-toggle"].tap()
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))

        // Git from the chat bar opens full screen and closes with Done.
        git.tap()
        let cover = app.descendants(matching: .any)["first-mate-git"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-git-file-Sources/Receipts/ReceiptExporter.swift"].firstMatch.waitForExistence(timeout: 8))
        try capture("a2-live-git", app)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(cover.waitForNonExistence(timeout: 5))

        // A Workflow commit opens Git at that commit.
        app.buttons["first-mate-tab-workflow"].tap()
        let commit = app.buttons["first-mate-commit-c81d5e9f2a6b4c47"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5)); commit.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Add the iPad export UI test"].firstMatch.waitForExistence(timeout: 8))
        try capture("a2-live-git-commit", app)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(cover.waitForNonExistence(timeout: 5))

        // The inspector was opened explicitly, so portrait keeps it, floating
        // over the chat with Close; closed, portrait keeps two panes.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["first-mate-inspector-close"].waitForExistence(timeout: 5))
        XCTAssertTrue(info.exists)
        try capture("a2-live-portrait-floating", app)
        app.buttons["first-mate-inspector-close"].tap()
        XCTAssertTrue(info.waitForNonExistence(timeout: 5))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrFirstMateDemo", "-HerdrResetFirstMateScope",
            "-herdr.smartAlerts", "NO", "-herdr.ios.appearance.glass", "YES", "-herdr.ios.appearance.haze", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 12))
        return app
    }

    private func capture(_ name: String, _ app: XCUIApplication) throws {
        let screen = app.screenshot(), attachment = XCTAttachment(screenshot: screen)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-a2-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try screen.pngRepresentation.write(to: folder.appending(path: name + ".png"))
    }
}
