import XCTest

/// Run scripts/first-mate-ios-fixture.py before these optional integration checks.
/// The fixture uses the real companion API and ledger with agent execution disabled.
final class HerdrFirstMateServerUITests: XCTestCase {
    @MainActor
    func testAuthenticatedDirectionAndExactSavedHistory() async throws {
        continueAfterFailure = false
        let origin = URL(string: "http://localhost:9196")!
        let token = "synthetic-first-mate-ios-token"
        let health: [String: Any]
        do { health = try await get("/api/v1/health", origin: origin, token: token) }
        catch { throw XCTSkip("Start scripts/first-mate-ios-fixture.py to run the authenticated simulator check.") }
        guard health["session"] as? String == "synthetic-first-mate-ios" else {
            throw XCTSkip("Port 9196 does not contain the synthetic First Mate fixture.")
        }
        let listing = try await get("/api/v1/first-mate/features", origin: origin, token: token)
        let features = try XCTUnwrap(listing["features"] as? [[String: Any]])
        let feature = try XCTUnwrap(features.first { $0["title"] as? String == "Keep review evidence together" })
        let featureID = try XCTUnwrap(feature["id"] as? String)
        let before = try await get("/api/v1/first-mate/features/\(featureID)", origin: origin, token: token)
        let visits = try XCTUnwrap(before["visits"] as? [[String: Any]])
        let planningID = try XCTUnwrap(visits.first { $0["title"] as? String == "Planning" }?["id"] as? String)

        let app = XCUIApplication()
        app.launchArguments = ["-HerdrUITestServerURL", origin.absoluteString,
            "-HerdrUITestAPIToken", token, "-HerdrOpenFirstMate", "-HerdrResetFirstMateScope",
            "-herdr.firstMate.appearance", "light", "-herdr.smartAlerts", "NO"]
        app.launch()
        defer { app.terminate() }
        let row = app.buttons["first-mate-feature-ui-test-\(featureID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let composer = app.descendants(matching: .any)["first-mate-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        let direction = "Keep this at the human checkpoint. Mobile verification \(UUID().uuidString.prefix(8))."
        composer.tap()
        composer.typeText(direction)
        let send = app.buttons["first-mate-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "first-mate-message-", direction
        )).firstMatch.waitForExistence(timeout: 8))
        let after = try await get("/api/v1/first-mate/features/\(featureID)", origin: origin, token: token)
        let messages = try XCTUnwrap(after["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["text"] as? String == direction }.count, 1)
        XCTAssertEqual((after["visits"] as? [[String: Any]])?.count, visits.count)

        app.buttons["first-mate-open-workflow"].tap()
        let docs = app.buttons["first-mate-visit-documents-\(planningID)"]
        XCTAssertTrue(docs.waitForExistence(timeout: 6))
        docs.tap()
        app.buttons["Ownership map.md"].tap()
        let author = app.buttons["first-mate-document-author"]
        XCTAssertTrue(author.waitForExistence(timeout: 6))
        author.tap()
        let source = app.buttons["first-mate-source-details"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        XCTAssertTrue(app.staticTexts["fixture-architect"].waitForExistence(timeout: 4))
        let earlier = app.buttons["first-mate-load-earlier"]
        scrollTo(earlier, app: app)
        earlier.tap()
        XCTAssertTrue(app.staticTexts["200 of 235 saved messages"].waitForExistence(timeout: 6))
        earlier.tap()
        XCTAssertTrue(app.staticTexts["235 of 235 saved messages"].waitForExistence(timeout: 6))
        XCTAssertFalse(earlier.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "authenticated-native-session-history"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func get(_ path: String, origin: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: origin.appending(path: path))
        request.timeoutInterval = 3
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "FirstMateFixture", code: 1)
        }
        return object
    }
}
