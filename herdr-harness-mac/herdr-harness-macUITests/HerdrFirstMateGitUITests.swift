import XCTest

/// Synthetic end-to-end coverage for First Mate's Chat/Git state and pinned
/// Git windows. Every target comes from the built-in demo; no host workspace or
/// network connection participates.
final class HerdrFirstMateGitUITests: HerdrUITestCase {
    @MainActor
    func testDraftWorkspaceSelectionAndPinnedWindowIdentity() {
        let app = launchDemoApp()
        defer { app.terminate() }
        let firstMate = app.buttons["open-first-mate"]
        XCTAssertTrue(firstMate.waitForExistence(timeout: 10), "The Chat navigator should list First Mate")
        firstMate.click()

        let main = mainWindow(in: app)
        let composer = control("first-mate-composer", in: main)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "First Mate should open its selected demo feature")
        composer.click()
        composer.typeText(Self.draft)
        XCTAssertTrue(waitForValue(Self.draft, of: composer))

        selectFirstMateMode("Git", in: main, app: app)
        selectWorkspace(Self.workerTitle, in: main, app: app)
        expectWorkspaceContext(in: main, title: Self.workerTitle, path: Self.workerPath)

        let popOut = control("first-mate-git-open-window", in: main)
        XCTAssertTrue(popOut.waitForExistence(timeout: 5), "A selected Git workspace should support pop-out")
        bringForward(popOut, in: app)
        popOut.click()

        let workerWindow = waitForGitWindow(targetID: Self.workerTargetID, in: app)
        expectWorkspaceContext(in: workerWindow, title: Self.workerTitle, path: Self.workerPath)

        selectFirstMateMode("Chat", in: main, app: app)
        let restoredComposer = control("first-mate-composer", in: main)
        XCTAssertTrue(restoredComposer.waitForExistence(timeout: 5), "Returning to Chat should restore the composer")
        XCTAssertTrue(
            waitForValue(Self.draft, of: restoredComposer),
            "Switching through Git must preserve the unsent feature draft"
        )

        selectFirstMateMode("Git", in: main, app: app)
        selectWorkspace(Self.projectTitle, in: main, app: app)
        expectWorkspaceContext(in: main, title: Self.projectTitle, path: Self.projectPath)
        expectWorkspaceContext(in: workerWindow, title: Self.workerTitle, path: Self.workerPath)

        selectWorkspace(Self.workerTitle, in: main, app: app)
        expectWorkspaceContext(in: main, title: Self.workerTitle, path: Self.workerPath)
        let reopen = control("first-mate-git-open-window", in: main)
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        bringForward(reopen, in: app)
        reopen.click()

        XCTAssertTrue(
            waitForGitWindowToBecomeFront(targetID: Self.workerTargetID, in: app),
            "Reopening the same target should focus its existing Git window"
        )
        XCTAssertEqual(
            gitWindows(targetID: Self.workerTargetID, in: app).count,
            1,
            "The machine/feature/workspace identity must prevent duplicate Git windows"
        )
    }

    // MARK: - Controls

    @MainActor
    private func selectFirstMateMode(
        _ title: String,
        in window: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = control("first-mate-chat-git-picker", in: window)
        guard picker.waitForExistence(timeout: 5) else {
            XCTFail("First Mate should expose its Chat/Git picker", file: file, line: line)
            return
        }
        bringForward(picker, in: app)

        let exactLabel = NSPredicate(format: "label == %@", title)
        guard let segment = waitForFirst(
            of: [
                picker.buttons[title],
                picker.radioButtons[title],
                picker.descendants(matching: .any).matching(exactLabel).firstMatch,
            ],
            timeout: 5
        ) else {
            XCTFail("The First Mate picker should offer \(title)", file: file, line: line)
            return
        }
        segment.click()
    }

    @MainActor
    private func selectWorkspace(
        _ title: String,
        in window: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = control("first-mate-git-workspace-picker", in: window)
        guard picker.waitForExistence(timeout: 10) else {
            XCTFail("First Mate Git should expose its workspace picker", file: file, line: line)
            return
        }
        bringForward(picker, in: app)
        picker.click()

        guard let item = waitForFirst(
            of: [
                app.menuItems[title],
                app.menuBars.menuItems[title],
            ],
            timeout: 5
        ) else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("The Git workspace picker should offer \(title)", file: file, line: line)
            return
        }
        item.click()
    }

    @MainActor
    private func expectWorkspaceContext(
        in window: XCUIElement,
        title: String,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = control("first-mate-git-workspace-context", in: window)
        XCTAssertTrue(
            context.waitForExistence(timeout: 10),
            "Git should render workspace context",
            file: file,
            line: line
        )
        for fragment in [title, path] {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                    fragment,
                    fragment
                ),
                object: context
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [expectation], timeout: 5),
                .completed,
                "Git context should contain \(fragment)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Window-scoped queries

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

    @MainActor
    private func gitWindows(targetID: String, in app: XCUIApplication) -> [XCUIElement] {
        let identifier = "first-mate-git-window-\(targetID)"
        return app.windows.allElementsBoundByIndex.filter { window in
            guard window.exists else { return false }
            if window.identifier == identifier { return true }
            return control(identifier, in: window).exists
        }
    }

    @MainActor
    private func waitForGitWindow(
        targetID: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = gitWindows(targetID: targetID, in: app).first {
                return window
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline

        XCTFail("The requested First Mate Git window should open", file: file, line: line)
        return app.windows.firstMatch
    }

    @MainActor
    private func waitForGitWindowToBecomeFront(
        targetID: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if gitWindows(targetID: targetID, in: app).contains(where: { window in
                control("first-mate-git-workspace-context", in: window).isHittable
            }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
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

    /// Window-group presentation changes key-window status asynchronously. Cycle
    /// native windows until the requested control, not a coordinate, is hittable.
    @MainActor
    private func bringForward(_ anchor: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        guard anchor.exists else { return }
        for _ in 0..<attempts {
            if anchor.isHittable { return }
            app.typeKey("`", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private static let featureID = "demo-session-continuity"
    private static let projectTitle = "Project workspace"
    private static let projectPath = "/demo/herdr-companion"
    private static let workerID = "demo-worker"
    private static let workerTitle = "Implementation worker"
    private static let workerPath = "/demo/worktrees/implementation"
    private static let draft = "Keep this synthetic draft unsent"
    private static let workerTargetID = "demo|\(featureID)|\(workerID)"
}
