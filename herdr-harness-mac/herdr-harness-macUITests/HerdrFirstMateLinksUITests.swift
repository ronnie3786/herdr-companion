import XCTest

/// Synthetic coverage for prominent pull request access and the Documents/Links
/// inspector. Every value comes from the built-in demo; no server or network
/// destination participates, and Open is never clicked.
final class HerdrFirstMateLinksUITests: HerdrUITestCase {
    @MainActor
    func testProminentPullRequestsAndDocumentsLinksManagement() throws {
        let app = launchDemoApp()
        defer { app.terminate() }
        let firstMate = app.buttons["open-first-mate"]
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10), "The Chat navigator should list First Mate")
        firstMate.click()

        let main = mainWindow(in: app)

        // Overview leads with every saved PR and keeps general links out.
        let overviewSection = control("first-mate-pr-section-overview", in: main)
        XCTAssertTrue(overviewSection.waitForExistence(timeout: 10), "Overview should expose the pull request section")
        XCTAssertTrue(control("first-mate-pr-overview-title-demo-link-pr-7", in: main).waitForExistence(timeout: 5))
        XCTAssertFalse(
            control("first-mate-pr-overview-title-demo-link-share", in: main).exists,
            "General links must not be presented as pull requests"
        )
        let overviewTitle = control("first-mate-pr-overview-title-demo-link-pr-101", in: main)
        XCTAssertTrue(overviewTitle.waitForExistence(timeout: 5))
        let glance = app.text(containing: "The feature at a glance")
        XCTAssertTrue(glance.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            overviewTitle.frame.minY,
            glance.frame.minY,
            "Pull requests should precede ordinary overview content"
        )

        // The same PR leads Documents, above the Documents/Links control.
        control("first-mate-tab-documents", in: main).click()
        let documentsSection = control("first-mate-pr-section-documents", in: main)
        XCTAssertTrue(documentsSection.waitForExistence(timeout: 5))
        let picker = control("first-mate-documents-picker", in: main)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let documentsTitle = control("first-mate-pr-documents-title-demo-link-pr-101", in: main)
        XCTAssertTrue(documentsTitle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            documentsTitle.frame.maxY,
            picker.frame.minY + 1,
            "The PR section should sit above the Documents/Links control"
        )

        // The existing Documents sub-tab still lists and opens evidence.
        let plannerDocument = control("first-mate-document-doc-demo-planner", in: main)
        XCTAssertTrue(
            plannerDocument.waitForExistence(timeout: 5),
            "Documents should keep listing retained evidence"
        )
        plannerDocument.click()
        let closeResource = control("first-mate-resource-close", in: app)
        XCTAssertTrue(closeResource.waitForExistence(timeout: 5), "An existing document should still open")
        closeResource.click()
        XCTAssertFalse(
            closeResource.waitForExistence(timeout: 2),
            "Closing should dismiss the document sheet"
        )

        // Links lists PRs first, with general links separated and inspectable.
        selectSegment("Links", in: picker, app: app)
        let pullRequestTitle = control("first-mate-link-pr-title-demo-link-pr-101", in: main)
        XCTAssertTrue(pullRequestTitle.waitForExistence(timeout: 5))
        let otherLinkTitle = control("first-mate-link-other-title-demo-link-share", in: main)
        XCTAssertTrue(otherLinkTitle.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            pullRequestTitle.frame.minY,
            otherLinkTitle.frame.minY,
            "Pull requests should lead the Links collection"
        )
        XCTAssertLessThan(
            picker.frame.maxY,
            pullRequestTitle.frame.minY,
            "The Links collection should follow the Documents/Links control"
        )
        XCTAssertTrue(
            app.text(containing: "share.example.test:8443").waitForExistence(timeout: 5),
            "The saved host and port should stay visible"
        )
        XCTAssertTrue(
            app.text(containing: "?tab=links#evidence").waitForExistence(timeout: 5),
            "The saved query and fragment should stay visible"
        )

        // Copy confirms the action without opening the destination.
        let copy = control("first-mate-link-other-copy-demo-link-share", in: main)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        XCTAssertTrue(
            waitForLabel("Copied", of: copy),
            "Copy should confirm the saved destination was copied"
        )

        // Save a new synthetic link through the Add form.
        let addURL = control("first-mate-link-add-url", in: main)
        XCTAssertTrue(addURL.waitForExistence(timeout: 5))
        addURL.click()
        addURL.typeText("https://share.example.test:9443/added?tab=links#top")
        let addTitle = control("first-mate-link-add-title", in: main)
        addTitle.click()
        addTitle.typeText("Added synthetic link")
        control("first-mate-link-add-submit", in: main).click()
        XCTAssertTrue(
            app.text(containing: "Added synthetic link").waitForExistence(timeout: 5),
            "A saved link should appear in the Links collection"
        )

        // Hide, show hidden, and restore reversibly.
        let hide = control("first-mate-link-other-hide-demo-link-share", in: main)
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.click()
        XCTAssertFalse(
            control("first-mate-link-other-title-demo-link-share", in: main).waitForExistence(timeout: 2),
            "Hiding should remove the row from the default collection"
        )
        let showHidden = control("first-mate-links-show-hidden", in: main)
        XCTAssertTrue(showHidden.waitForExistence(timeout: 5))
        showHidden.click()
        XCTAssertTrue(
            control("first-mate-link-hidden-title-demo-link-share", in: main).waitForExistence(timeout: 5),
            "Show hidden should reveal the hidden link"
        )
        let restore = control("first-mate-link-hidden-restore-demo-link-share", in: main)
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "Hidden links should be reversible")
        restore.click()
        XCTAssertTrue(
            control("first-mate-link-other-title-demo-link-share", in: main).waitForExistence(timeout: 5),
            "Restoring should return the link to its collection"
        )

        // A second feature with no links shows empty states.
        control("first-mate-feature-demo-search", in: main).click()
        XCTAssertTrue(
            control("first-mate-pr-empty-documents", in: main).waitForExistence(timeout: 5),
            "A feature with no links should show an empty PR state"
        )

        // Returning confirms documents were never converted into links.
        control("first-mate-feature-demo-session-continuity", in: main).click()
        XCTAssertTrue(control("first-mate-pr-documents-title-demo-link-pr-101", in: main).waitForExistence(timeout: 5))
        let restoredPicker = control("first-mate-documents-picker", in: main)
        XCTAssertTrue(restoredPicker.waitForExistence(timeout: 5))
        selectSegment("Documents", in: restoredPicker, app: app)
        XCTAssertTrue(
            control("first-mate-document-doc-demo-planner", in: main).waitForExistence(timeout: 5),
            "Document browsing must survive link management"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func selectSegment(
        _ title: String,
        in picker: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let exactLabel = NSPredicate(format: "label == %@", title)
        guard let segment = waitForFirst(
            of: [
                picker.buttons[title],
                picker.radioButtons[title],
                picker.descendants(matching: .any).matching(exactLabel).firstMatch,
            ],
            timeout: 5
        ) else {
            XCTFail("The Documents/Links control should offer \(title)", file: file, line: line)
            return
        }
        segment.click()
    }

    @MainActor
    private func waitForLabel(
        _ label: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func control(_ identifier: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func mainWindow(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            for window in app.windows.allElementsBoundByIndex where window.exists {
                if control("nav-history-controls", in: window).exists {
                    return window
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline

        XCTFail("The main shell window should be addressable", file: file, line: line)
        return app.windows.firstMatch
    }
}
