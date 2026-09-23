import XCTest

/// Deterministic coverage for the report sheet's optional smart input.
///
/// Every fixture-backed test launches the synthetic demo fleet with the
/// DEBUG-only `-HerdrIssueReportFixture` argument, so drafting and "recording"
/// use network-free, microphone-free doubles with stable timing and output.
/// No test files an issue, contacts a companion, or requests microphone
/// permission; the same tests document the absence of any recorder sheet,
/// waveform, timer, or playback UI.
final class IssueReportSmartInputUITests: HerdrUITestCase {
    @MainActor
    func testTypedPlainEnglishDraftsBothKindsAndStaysEditable() {
        let app = launchReportSheet(fixture: true)
        defer { app.terminate() }

        let source = app.textViews["issue-report-smart-source"]
        let title = app.textFields["issue-report-title"]
        let body = app.textViews["issue-report-body"]
        XCTAssertTrue(source.exists, "The smart input sits above the title and description")
        XCTAssertTrue(title.exists)
        XCTAssertTrue(body.exists)

        // R1: the sheet opens with the plain-English box focused, so typing
        // needs no click, and an empty title/description is no obstacle.
        app.typeText("it crashes when I open two windows")
        XCTAssertTrue(
            waitForValue(source, "it crashes when I open two windows"),
            "Typing should land in the initially focused smart-input box"
        )

        let draft = app.control(identifier: "issue-report-smart-draft")
        let submit = app.control(identifier: "issue-report-submit")
        XCTAssertTrue(draft.isEnabled, "Plain English alone enables the explicit AI action")
        XCTAssertFalse(submit.isEnabled, "The report has no title or description yet")
        draft.click()

        // R2: immediate progress and duplicate-click suppression while busy.
        XCTAssertTrue(
            app.control(identifier: "issue-report-smart-status").waitForExistence(timeout: 3),
            "Drafting should show progress immediately"
        )
        XCTAssertFalse(draft.isEnabled)
        XCTAssertFalse(submit.isEnabled, "File report stays unavailable during preparation")

        // R3: one validated draft fills both fields; the source text stays.
        XCTAssertTrue(waitForValue(title, "Synthetic bug draft"))
        XCTAssertTrue(waitForValue(body, "Synthetic bug description", contains: true))
        XCTAssertEqual(source.value as? String, "it crashes when I open two windows")
        XCTAssertTrue(app.control(identifier: "issue-report-smart-restore").exists)
        XCTAssertTrue(submit.isEnabled, "Preparing never leaves filing blocked")

        // The generated fields stay editable, and a manual edit wins over the
        // one-step restoration.
        title.click()
        title.typeKey(.rightArrow, modifierFlags: .command)
        title.typeText(" — edited")
        XCTAssertTrue(waitForValue(title, " — edited", contains: true))
        XCTAssertTrue(waitForValue(body, "Synthetic bug description", contains: true))
        XCTAssertFalse(app.control(identifier: "issue-report-smart-restore").exists)

        // The same box drafts the Feature form with feature structure.
        guard let feature = waitForFirst(
            of: [app.radioButtons["Feature request"], app.control(named: "Feature request")]
        ) else {
            XCTFail("The Feature request segment is missing")
            return
        }
        feature.click()
        draft.click()
        XCTAssertTrue(waitForValue(title, "Synthetic feature draft"))
        XCTAssertTrue(waitForValue(body, "Synthetic feature description", contains: true))

        // Restoration replaces the feature draft with the fields it replaced,
        // then consumes itself.
        let restore = app.control(identifier: "issue-report-smart-restore")
        XCTAssertTrue(restore.exists)
        restore.click()
        XCTAssertTrue(waitForValue(title, " — edited", contains: true))
        XCTAssertTrue(waitForValue(body, "Synthetic bug description", contains: true))
        XCTAssertFalse(app.control(identifier: "issue-report-smart-restore").exists)
    }

    @MainActor
    func testInlineMicrophoneTranscribesOnStopWithoutARecorderSheet() {
        let app = launchReportSheet(fixture: true)
        defer { app.terminate() }

        let source = app.textViews["issue-report-smart-source"]
        source.click()
        source.typeText("typed before dictation")

        let sheetWindows = app.windows.count
        let mic = app.control(identifier: "issue-report-smart-mic")
        XCTAssertTrue(mic.isEnabled)
        XCTAssertEqual(mic.label, "Record a description")
        mic.click()

        // The glow's accessible evidence, not the glow itself: the same
        // inline control becomes Stop, the status is explicit, and nothing
        // else appears.
        let status = app.control(identifier: "issue-report-smart-status")
        XCTAssertTrue(waitForLabel(mic, "Stop recording"))
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForLabel(status, "Recording…"))
        XCTAssertLessThanOrEqual(app.windows.count, sheetWindows, "Recording must not open a recorder window")
        XCTAssertFalse(app.control(identifier: "issue-report-recorder").exists)
        XCTAssertFalse(app.control(identifier: "issue-report-player").exists)
        XCTAssertFalse(app.control(identifier: "issue-report-smart-draft").isEnabled, "Recording blocks AI drafting")
        XCTAssertFalse(app.control(identifier: "issue-report-submit").isEnabled, "Recording blocks filing")
        XCTAssertTrue(source.exists, "The smart input stays in place while recording")
        XCTAssertTrue(app.textFields["issue-report-title"].exists)

        // R5: Stop transcribes once into the same box and does nothing else.
        mic.click()
        XCTAssertTrue(waitForLabel(status, "Transcribing…"))
        XCTAssertTrue(waitForValue(source, "Synthetic dictated request", contains: true))
        XCTAssertEqual(
            source.value as? String,
            "typed before dictation\n\nSynthetic dictated request for the smart input box."
        )
        XCTAssertTrue(waitForLabel(mic, "Record a description"))
        XCTAssertFalse(app.control(identifier: "issue-report-submit").isEnabled, "Transcription never files a report")
        XCTAssertTrue(app.control(identifier: "issue-report-smart-draft").isEnabled)
    }

    @MainActor
    func testDraftFailureIsRecoverableAndPreparationBlocksFiling() {
        let app = launchReportSheet(fixture: true, transientFailure: true)
        defer { app.terminate() }

        // Valid manual fields, so File report would otherwise be enabled.
        let title = app.textFields["issue-report-title"]
        title.click()
        title.typeText("Manual title")
        let body = app.textViews["issue-report-body"]
        body.click()
        body.typeText("Manual description")
        let submit = app.control(identifier: "issue-report-submit")
        XCTAssertTrue(submit.isEnabled)

        let source = app.textViews["issue-report-smart-source"]
        source.click()
        source.typeText("make the sidebar remember my last machine")
        let draft = app.control(identifier: "issue-report-smart-draft")
        draft.click()

        // Busy controls: progress is immediate, no duplicate run, no filing.
        XCTAssertTrue(app.control(identifier: "issue-report-smart-status").waitForExistence(timeout: 3))
        XCTAssertFalse(draft.isEnabled)
        XCTAssertFalse(submit.isEnabled)

        // The first fixture run fails actionably; typed text and manual fields
        // survive, and filing becomes available again.
        let error = app.control(identifier: "issue-report-smart-draft-error")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.text(containing: "synthetic drafting provider").exists)
        XCTAssertEqual(source.value as? String, "make the sidebar remember my last machine")
        XCTAssertEqual(title.value as? String, "Manual title")
        XCTAssertEqual(body.value as? String, "Manual description")
        XCTAssertTrue(submit.isEnabled)

        // One explicit retry recovers.
        app.control(identifier: "issue-report-smart-retry").click()
        XCTAssertTrue(waitForValue(title, "Synthetic bug draft"))
        XCTAssertTrue(waitForValue(body, "Synthetic bug description", contains: true))
        XCTAssertFalse(app.control(identifier: "issue-report-smart-draft-error").exists)
    }

    @MainActor
    func testManualReportingRemainsAvailableWithoutDraftingSupport() {
        let app = launchReportSheet(fixture: false)
        defer { app.terminate() }

        // Demo mode has no drafting companion: only the optional AI action is
        // unavailable, and the notice explains it.
        let source = app.textViews["issue-report-smart-source"]
        XCTAssertTrue(source.exists)
        let draft = app.control(identifier: "issue-report-smart-draft")
        XCTAssertFalse(draft.isEnabled)
        XCTAssertTrue(
            app.control(identifier: "issue-report-smart-availability").waitForExistence(timeout: 10),
            "The unsupported state needs a visible notice"
        )
        XCTAssertEqual((source.value as? String) ?? "", "")

        // Hand-written reports are untouched.
        let title = app.textFields["issue-report-title"]
        title.click()
        title.typeText("Hand-written title")
        let body = app.textViews["issue-report-body"]
        body.click()
        body.typeText("Hand-written description")
        XCTAssertTrue(app.control(identifier: "issue-report-submit").isEnabled)
    }

    // MARK: - Helpers

    @MainActor
    private func launchReportSheet(fixture: Bool, transientFailure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"]
        if fixture { arguments.append("-HerdrIssueReportFixture") }
        if transientFailure { arguments.append("-HerdrIssueReportFixtureDraftFailure") }
        app.launchArguments = arguments
        app.launch()
        openReportSheet(app)
        return app
    }

    @MainActor
    private func openReportSheet(_ app: XCUIApplication) {
        XCTAssertTrue(app.shellWindow.waitForExistence(timeout: 15), "The main window should appear")
        guard let item = app.menuBarItem("Help", item: "Report a Bug or Request a Feature…") else {
            XCTFail("Help ▸ Report a Bug or Request a Feature… is missing")
            return
        }
        item.click()
        XCTAssertTrue(
            app.control(identifier: "issue-report-smart-source").waitForExistence(timeout: 10),
            "The report sheet should open with the smart-input box"
        )
    }

    @MainActor
    private func waitForValue(
        _ element: XCUIElement,
        _ fragment: String,
        contains: Bool = false,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = element.value as? String {
                if contains ? value.contains(fragment) : value == fragment { return true }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.label == label { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }
}
