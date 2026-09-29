import XCTest

@MainActor
final class HerdrFirstMateConversationsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testConversationsLeadChatSearchAndHostScope() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.buttons["First Mates"].exists)
        for id in ["first-mate-machine-picker", "first-mate-chat-search-toggle", "first-mate-new-feature", "first-mate-options"] {
            assertTarget(app.buttons[id])
        }
        try capture("phase2-list-top", app)
        let lead = app.buttons["first-mate-chat-pinned-lead"]
        XCTAssertTrue(lead.isHittable)
        assertTarget(lead)
        lead.tap()
        XCTAssertTrue(app.staticTexts["first-mate-briefing-disclosure"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["first-mate-briefing-disclosure"].label.contains("Not a message from an agent"))
        try capture("phase2-lead-briefing", app)
        app.navigationBars.buttons.firstMatch.tap()
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        reach(receipt, app)
        receipt.tap()
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-composer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Receipt export"].exists)
        try capture("phase2-existing-receipt-chat", app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["first-mate-chat-search-toggle"].tap()
        let search = app.textFields["first-mate-chat-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Receipt export")
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["first-mate-chat-pinned-lead"].exists)
        try capture("phase2-search", app)
        app.buttons["first-mate-chat-search-toggle"].tap()
        selectMachine("desktop", app)
        XCTAssertTrue(app.buttons["first-mate-machine-picker"].label.contains("desktop"))
        XCTAssertFalse(app.buttons["first-mate-feature-demo2-demo2-release-checklist"].exists)
        selectMachine("All Machines", app)
    }

    func testCreateAndArchiveRemainExactOwnerAndAccessibleAtTheCap() throws {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        defer { app.terminate() }
        app.buttons["first-mate-new-feature"].tap()
        let destination = app.buttons["first-mate-create-machine"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.label.contains("Choose a machine"))
        assertTarget(destination)
        destination.tap()
        app.buttons["laptop"].firstMatch.tap()
        let title = app.descendants(matching: .any)["first-mate-create-title"]
        reach(title, app); title.tap(); title.typeText("Synthetic phone checklist")
        app.buttons["first-mate-create-keyboard-done"].tap()
        let goal = app.descendants(matching: .any)["first-mate-create-goal"]
        reach(goal, app); goal.tap(); goal.typeText("Retain the evidence on this host.")
        app.buttons["first-mate-create-keyboard-done"].tap()
        let folder = app.descendants(matching: .any)["first-mate-create-folder"]
        reach(folder, app); folder.tap(); folder.typeText("/workspace/synthetic")
        app.buttons["first-mate-create-keyboard-done"].tap()
        let submit = app.buttons["first-mate-create-submit"]
        reach(submit, app); assertTarget(submit)
        XCTAssertTrue(submit.isEnabled)
        try capture("phase2-create-capped", app)
        submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-composer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Synthetic phone checklist"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        reach(receipt, app)
        receipt.swipeLeft()
        let archive = app.buttons["first-mate-archive-demo1-demo-receipts"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5)); archive.tap()
        let reason = app.buttons["first-mate-archive-reason-duplicate"]
        reach(reason, app); assertTarget(reason); reason.tap()
        let confirm = app.buttons["first-mate-confirm-archive"]
        reach(confirm, app); assertTarget(confirm)
        try capture("phase2-archive-capped", app)
        confirm.tap()
        XCTAssertTrue(app.buttons["first-mate-options"].waitForExistence(timeout: 5))
        XCTAssertFalse(receipt.exists)
        app.buttons["first-mate-options"].tap()
        app.buttons["first-mate-show-archived"].tap()
        reach(receipt, app)
        XCTAssertTrue(receipt.label.contains("Archived"))
        receipt.swipeLeft()
        let restore = app.buttons["first-mate-unarchive-demo1-demo-receipts"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
    }

    func testOneHundredRowsUseLazyBodiesAndScrollToTheEnd() throws {
        let app = launch(extra: ["-HerdrFirstMateListPerformance"])
        defer { app.terminate() }
        selectMachine("desktop", app)
        let initial = diagnostics(app)
        print("HERDR_PHASE2_PERFORMANCE_INITIAL \(initial)")
        XCTAssertLessThan(initial["bodies"] ?? 100, 100, "The List must not evaluate all 100 row bodies at launch")
        XCTAssertLessThan(initial["peak"] ?? 100, 50)
        let overflow = app.buttons["first-mate-chat-pinned-overflow"]
        let strip = app.scrollViews["first-mate-chat-pinned-strip"]
        for _ in 0..<5 {
            if overflow.exists && app.frame.contains(overflow.frame) && overflow.isHittable { break }
            strip.swipeLeft()
        }
        XCTAssertTrue(overflow.exists && app.frame.contains(overflow.frame) && overflow.isHittable)
        overflow.tap()
        let firstHidden = app.buttons["first-mate-feature-demo1-performance-006"]
        XCTAssertTrue(firstHidden.waitForExistence(timeout: 5) && firstHidden.isHittable)
        XCTAssertLessThan(firstHidden.frame.minY, 240, "Overflow must scroll to the first hidden feature")
        let last = app.buttons["first-mate-feature-demo1-performance-099"]
        let start = Date()
        var swipes = 0
        while swipes < 35 && !(last.exists && last.isHittable && app.frame.insetBy(dx: 0, dy: 95).contains(last.frame)) {
            swipeUp(app); swipes += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(last.exists && last.isHittable)
        try capture("phase2-performance-last-row", app)
        let final = diagnostics(app)
        XCTAssertGreaterThan(final["appeared"] ?? 0, initial["appeared"] ?? 0)
        XCTAssertLessThan(final["peak"] ?? 100, 60)
        let evidence = "100 synthetic rows; initial=\(initial); final=\(final); swipes=\(swipes); XCTest gesture/settling seconds=\(elapsed). No FPS claim."
        print("HERDR_PHASE2_PERFORMANCE \(evidence)")
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "phase2-100-row-observation"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrFirstMateDemo", "-HerdrResetFirstMateScope", "-herdr.smartAlerts", "NO"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 10), app.debugDescription)
        return app
    }
    private func selectMachine(_ name: String, _ app: XCUIApplication) {
        app.buttons["first-mate-machine-picker"].tap()
        let choice = app.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
    }
    private func assertTarget(_ element: XCUIElement) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 0.001)
    }
    private func visibleContent(_ app: XCUIApplication) -> CGRect {
        let top = app.frame.minY + 95
        let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 12 : app.frame.maxY - 95
        return CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: max(60, bottom - top))
    }
    private func swipeUp(_ app: XCUIApplication) {
        let visible = visibleContent(app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = visible.maxX - 10 // Gutter: avoid dragging inside an editing TextField.
        origin.withOffset(.init(dx: x, dy: visible.maxY - 20)).press(forDuration: 0.03,
            thenDragTo: origin.withOffset(.init(dx: x, dy: visible.minY + 30)))
    }
    private func reach(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<24 {
            let visible = visibleContent(app)
            if element.exists && element.isHittable && visible.contains(element.frame) { return }
            if element.exists && element.frame.minY < visible.minY {
                app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.35)).press(forDuration: 0.03,
                    thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.75)))
            } else { swipeUp(app) }
        }
        XCTAssertTrue(element.exists && element.isHittable, element.debugDescription)
    }
    private func diagnostics(_ app: XCUIApplication) -> [String: Int] {
        app.buttons["first-mate-options"].tap()
        app.buttons["first-mate-list-diagnostics"].tap()
        let alert = app.alerts["List diagnostics"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).first { $0.contains("bodies=") } ?? ""
        let result = Dictionary(text.split(separator: ";").compactMap { part -> (String, Int)? in
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=")
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            return (String(pair[0]), value)
        }, uniquingKeysWith: { _, last in last })
        alert.buttons["OK"].tap()
        return result
    }
    private func capture(_ name: String, _ app: XCUIApplication) throws {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-conversation-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image.pngRepresentation.write(to: folder.appending(path: name + ".png"))
    }
}
