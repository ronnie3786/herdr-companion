import XCTest
import UIKit

@MainActor
final class HerdrFirstMatePolishUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPhoneInfoResourcesAndAppWideTextCap() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Phone acceptance") }
        let app = launch(); defer { app.terminate() }
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        reach(receipt, in: app); receipt.tap()
        app.buttons["first-mate-chat-inspector-toggle"].tap()
        XCTAssertTrue(app.otherElements["first-mate-info-screen"].waitForExistence(timeout: 5))
        for tab in ["overview", "agents", "documents", "workflow"] {
            selectInfo(tab, app)
            assertCap(app)
            let footer = app.descendants(matching: .any)["first-mate-sync-footer"].firstMatch
            XCTAssertTrue(footer.exists)
            XCTAssertTrue(app.frame.contains(footer.frame))
            try capture("phase6-live-info-\(tab)-capped", app)
        }
        selectInfo("documents", app)
        let document = app.buttons["first-mate-document-demo-receipts-document-2"]
        reach(document, in: app); document.tap()
        let close = app.buttons["first-mate-resource-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); target(close, app)
        assertCap(app)
        try capture("phase6-live-document-capped", app)
        close.tap()
        selectInfo("agents", app)
        let agent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "first-mate-agent-demo-receipts-")).firstMatch
        reach(agent, in: app); agent.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        target(close, app)
        XCTAssertTrue(app.navigationBars["Saved session"].exists)
        try capture("phase6-live-session-capped", app)
        close.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["first-mate-chat-back"].tap()
        for tab in ["Agents", "Attention", "Notes", "Settings", "First Mates"] {
            selectAppTab(tab, app)
            assertCap(app)
            try app.performAccessibilityAudit(for: .sufficientElementDescription)
            try capture("phase6-app-\(tab.lowercased().replacingOccurrences(of: " ", with: "-"))-capped", app)
        }
        selectAppTab("Notes", app)
        target(app.buttons["notes-machine-picker"], app)
        let note = app.buttons["notes-card-demo1|11111111-1111-1111-1111-111111111111"]
        reach(note, in: app); note.tap()
        let body = app.staticTexts["note-full-body"]
        reach(body, in: app)
        XCTAssertTrue(body.label.contains("Review the new HUD bubbles."))
        try capture("phase6-note-detail-capped", app)
    }

    func testIPadSelectionInfoAndDraftSurviveRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Dedicated iPad acceptance") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 10)); receipt.tap()
        try capture("phase6-ipad-after-selection", app)
        XCTAssertTrue(app.buttons["first-mate-tab-overview"].waitForExistence(timeout: 5))
        assertColumns(app)
        let input = app.descendants(matching: .any)["first-mate-composer"].firstMatch
        input.tap(); input.typeText("Retain this exact iPad draft")
        selectInfo("documents", app)
        XCTAssertTrue(app.staticTexts["first-mate-documents"].exists)
        try capture("phase6-live-ipad-1366-capped", app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["first-mate-chat-title"].waitForExistence(timeout: 5))
        assertColumns(app)
        XCTAssertEqual(input.value as? String, "Retain this exact iPad draft")
        XCTAssertTrue(app.staticTexts["first-mate-documents"].exists)
        assertCap(app)
        try capture("phase6-live-ipad-1024-capped", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let other = app.buttons["first-mate-feature-demo1-demo-search"]
        XCTAssertTrue(other.waitForExistence(timeout: 5)); other.tap()
        XCTAssertTrue(app.staticTexts["first-mate-overview"].waitForExistence(timeout: 5), "A different feature starts at Overview")
        receipt.tap()
        XCTAssertEqual(input.value as? String, "Retain this exact iPad draft")
    }

    func testGlobalLeadReturnsFromFeatureAndFollowsChoiceAcrossSizeClasses() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Dedicated iPad size-class acceptance") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(extra: ["-HerdrFirstMateSizeClassScenarios", "-HerdrFirstMateLeadScenarios"])
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.buttons["first-mate-chat-pinned-lead"].tap()
        let machineMenu = app.buttons["first-mate-lead-machine-menu"]
        XCTAssertTrue(machineMenu.waitForExistence(timeout: 5)); machineMenu.tap()
        app.buttons["first-mate-lead-automatic"].tap()
        leadOwner("desktop", app)
        app.buttons["first-mate-chat-inspector-toggle"].tap()
        let receipt = app.buttons["first-mate-briefing-feature-demo1-demo-receipts"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5)); receipt.tap()
        let open = app.buttons["first-mate-readout-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(app.buttons["first-mate-chat-title"].label.contains("Receipt export"))
        app.buttons["first-mate-chat-back"].tap()
        XCTAssertTrue(app.staticTexts["Your features at a glance"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        leadOwner("desktop", app)
        app.buttons["size-class-regular"].tap()
        XCTAssertTrue(machineMenu.waitForExistence(timeout: 5), "The global lead retains its machine chooser in regular layout")
        leadOwner("desktop", app)
        for _ in 0..<2 {
            app.buttons["first-mate-lead-options"].tap()
            app.buttons["Fail preferred LIST poll"].tap()
        }
        leadOwner("laptop", app)
        XCTAssertTrue(app.staticTexts["first-mate-lead-offline"].exists)
        try capture("phase6-lead-regular-after-back-and-failover", app)
        app.buttons["size-class-compact"].tap()
        leadOwner("laptop", app)
        XCTAssertTrue(machineMenu.exists)
        app.buttons["first-mate-lead-options"].tap()
        app.buttons["Recover preferred machine"].tap()
        leadOwner("desktop", app)
    }

    private func leadOwner(_ name: String, _ app: XCUIApplication) {
        let owner = app.staticTexts["first-mate-lead-owner"]
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label BEGINSWITH %@", name + " ·"), object: owner)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrFirstMateDemo", "-HerdrResetFirstMateScope", "-HerdrAppAppearanceProbe",
            "-herdr.smartAlerts", "NO", "-herdr.ios.appearance.glass", "YES", "-herdr.ios.appearance.haze", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 12))
        return app
    }
    private func selectAppTab(_ title: String, _ app: XCUIApplication) {
        let button = app.tabBars.buttons[title]
        button.tap()
        if !button.wait(for: \.isSelected, toEqual: true, timeout: 2) {
            button.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: 3), "Expected \(title) tab")
    }
    private func assertCap(_ app: XCUIApplication) {
        let probe = app.staticTexts["app-text-size-probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertEqual(probe.label, "Text size: xxxLarge")
    }
    private func target(_ element: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(element.exists && element.isHittable, element.debugDescription)
        XCTAssertFalse(element.label.isEmpty)
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.99)
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.99)
        XCTAssertTrue(app.frame.contains(element.frame))
    }
    private func selectInfo(_ name: String, _ app: XCUIApplication) {
        let tab = app.buttons["first-mate-tab-\(name)"]
        for _ in 0..<5 {
            if tab.isHittable && app.frame.contains(tab.frame) { break }
            let strip = app.descendants(matching: .any)["first-mate-info-tabs"].firstMatch
            if name == "overview" || name == "agents" { strip.swipeRight() } else { strip.swipeLeft() }
        }
        target(tab, app); tab.tap()
    }
    private func reach(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.minY >= 100 && element.frame.maxY < app.frame.maxY - 110 { return }
            app.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.74)).press(forDuration: 0.03,
                thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.27)))
        }
        XCTAssertTrue(element.exists && element.isHittable, element.debugDescription)
    }
    private func assertColumns(_ app: XCUIApplication) {
        let list = app.buttons["first-mate-feature-demo1-demo-receipts"]
        let chat = app.buttons["first-mate-chat-title"]
        let info = app.otherElements["first-mate-info-column"].firstMatch
        XCTAssertTrue(list.isHittable && chat.exists && info.exists)
        XCTAssertLessThanOrEqual(list.frame.maxX, chat.frame.minX + 1)
        XCTAssertLessThanOrEqual(chat.frame.maxX, info.frame.minX + 1)
        XCTAssertTrue(app.frame.contains(info.frame))
    }
    private func capture(_ name: String, _ app: XCUIApplication) throws {
        let screen = app.screenshot(), attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-polish-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try screen.pngRepresentation.write(to: folder.appending(path: name + ".png"))
    }
}
