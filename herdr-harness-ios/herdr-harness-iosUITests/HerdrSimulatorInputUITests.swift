import XCTest

final class HerdrSimulatorInputUITests: XCTestCase {
    @MainActor
    func testTouchSwipeHomeLockAndTypingReachSimPortal() async throws {
        continueAfterFailure = false
        guard let fixture = ProcessInfo.processInfo.environment["HERDR_SIMULATOR_RELAY_FIXTURE"] else {
            throw XCTSkip("Start scripts/simulator-preview-fixture.py and pass its JSON as HERDR_SIMULATOR_RELAY_FIXTURE.")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        let origin = try XCTUnwrap(object["base_url"] as? String)
        let token = try XCTUnwrap(object["token"] as? String)
        let before = try await messages(origin: origin, token: token).count
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrSimulatorInputFixture"]
        app.launchEnvironment["HERDR_SIMULATOR_RELAY_FIXTURE"] = fixture
        app.launch()
        defer { app.terminate() }
        app.buttons["Open fixture simulator"].tap()
        let home = app.buttons["first-mate-simulator-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: enabled, object: home)], timeout: 15)
        let screen = app.descendants(matching: .any)["first-mate-simulator-screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).tap()
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        home.tap()
        app.buttons["first-mate-simulator-lock"].tap()
        app.buttons["first-mate-simulator-type"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("Synthetic typing")
        app.alerts.buttons["Send"].tap()

        var sent: [[String: Any]] = []
        for _ in 0..<50 {
            sent = Array(try await messages(origin: origin, token: token).dropFirst(before))
            if sent.contains(where: { $0["text"] as? String == "Synthetic typing" }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(sent.filter { $0["type"] as? String == "touch" && $0["phase"] as? String == "began" }.count, 2)
        XCTAssertEqual(sent.filter { $0["type"] as? String == "touch" && $0["phase"] as? String == "ended" }.count, 2)
        XCTAssertTrue(sent.contains { $0["type"] as? String == "touch" && $0["phase"] as? String == "moved" })
        XCTAssertEqual(sent.compactMap { $0["button"] as? String }, ["home", "lock"])
        XCTAssertEqual(sent.compactMap { $0["text"] as? String }, ["Synthetic typing"])
        app.buttons["first-mate-simulator-stream-options"].tap()
        app.buttons["Reconnect"].tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: enabled, object: home)], timeout: 15)
        home.tap()
        for _ in 0..<50 {
            sent = Array(try await messages(origin: origin, token: token).dropFirst(before))
            if sent.filter({ $0["button"] as? String == "home" }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(sent.filter { $0["type"] as? String == "hello" }.count, 2)
        XCTAssertEqual(sent.compactMap { $0["button"] as? String }, ["home", "lock", "home"])
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iPad simulator after forwarded input"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["first-mate-simulator-done"].tap()
        XCTAssertTrue(app.buttons["Open fixture simulator"].waitForExistence(timeout: 5))
    }

    private func messages(origin: String, token: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: origin + "/fixture/viewer-messages")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["messages"] as? [[String: Any]])
    }
}
