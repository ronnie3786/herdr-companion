import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

/// Native renders of the Car mode card, agent detail, and voice layer across
/// realistic phone widths and text sizes. The geometry that matters here is the
/// size of a target you are supposed to hit while driving.
@MainActor
final class CarModeRenderTests: XCTestCase {
    private let harness = IOSNativeRenderHarness()
    private let widths: [CGFloat] = [320, 375, 430]
    private let dynamicTypeSizes: [IOSNativeRenderHarness.DynamicTypeFixture] = [
        .defaultSize,
        .accessibility3,
    ]

    func testPortraitCardsKeepLargeTargetsAtEveryWidth() async throws {
        let directory = try renderDirectory()
        print("HERDR_CAR_MODE_RENDER_DIR=\(directory.path)")

        for dynamicType in dynamicTypeSizes {
            let scale = CarModeMetrics.scale(for: dynamicType.swiftUI)
            for width in widths {
                for (name, summary) in cardFixtures {
                    let entry = try fixtureEntry(summary: summary)
                    let card = CarAgentCardView(
                        entry: entry,
                        scale: scale,
                        isWide: false,
                        isVoiceTarget: false,
                        open: {},
                        play: {},
                        respond: {}
                    )
                    .frame(height: CarModeMetrics.scaled(CarModeMetrics.portraitCardMinHeight, by: scale) * 1.06)
                    .padding(.horizontal, CarModeMetrics.pagePadding)

                    let render = await harness.render(card, width: width, dynamicType: dynamicType)
                    let context = "\(name), \(Int(width))pt, \(dynamicType.name)"
                    try save(render: render, name: "card-\(name)-\(Int(width))-\(dynamicType.name)", directory: directory)

                    XCTAssertTrue(render.drewHierarchy, context)
                    try assertTargets(render, entry: entry, context: context, minimum: CarModeMetrics.minimumActionHeight)
                    // The one-line status must actually have room to be read.
                    let summaryFrame = try XCTUnwrap(
                        render.element(identifier: "car-summary-\(entry.id)"),
                        "No status line rendered: \(context)"
                    )
                    XCTAssertGreaterThan(summaryFrame.frame.width, 120, "Status line is too narrow: \(context)")
                    XCTAssertGreaterThan(summaryFrame.frame.height, 8, "Status line collapsed: \(context)")
                    // The two actions share the row instead of stacking or clipping.
                    let audio = try XCTUnwrap(render.element(identifier: "car-audio-\(entry.id)"))
                    let reply = try XCTUnwrap(render.element(identifier: "car-reply-\(entry.id)"))
                    XCTAssertEqual(audio.frame.midY, reply.frame.midY, accuracy: 2, "Actions should share one row: \(context)")
                    XCTAssertLessThan(audio.frame.maxX, reply.frame.maxX + 1, "Actions should not overlap: \(context)")
                }
            }
        }
    }

    func testLandscapeRowsKeepTargetsInsideAFixedRow() async throws {
        let directory = try renderDirectory()
        for dynamicType in dynamicTypeSizes {
            let scale = CarModeMetrics.scale(for: dynamicType.swiftUI)
            let entry = try fixtureEntry(summary: questionSummary)
            let row = CarAgentCardView(
                entry: entry,
                scale: scale,
                isWide: true,
                isVoiceTarget: false,
                open: {},
                play: {},
                respond: {}
            )
            .frame(height: CarModeMetrics.scaled(CarModeMetrics.landscapeRowMinHeight, by: scale) * 1.06)
            .padding(.horizontal, CarModeMetrics.pagePadding)

            let render = await harness.render(row, width: 852, dynamicType: dynamicType)
            try save(render: render, name: "landscape-row-\(dynamicType.name)", directory: directory)

            try assertTargets(
                render,
                entry: entry,
                context: "landscape, \(dynamicType.name)",
                minimum: CarModeMetrics.minimumActionHeight
            )
        }
    }

    func testAgentDetailKeepsAVoiceOnlyReplyTarget() async throws {
        let directory = try renderDirectory()
        for dynamicType in dynamicTypeSizes {
            let scale = CarModeMetrics.scale(for: dynamicType.swiftUI)
            for isWide in [false, true] {
                let entry = try fixtureEntry(summary: answerSummary)
                let detail = CarAgentDetailView(
                    entry: entry,
                    scale: scale,
                    isWide: isWide,
                    isRecording: false,
                    back: {},
                    play: {},
                    respond: {}
                )
                .frame(height: isWide ? 393 : 700)

                let render = await harness.render(
                    detail,
                    width: isWide ? 852 : 393,
                    dynamicType: dynamicType
                )
                let context = "detail, \(isWide ? "wide" : "portrait"), \(dynamicType.name)"
                try save(render: render, name: "detail-\(isWide ? "wide" : "portrait")-\(dynamicType.name)", directory: directory)

                let mic = try XCTUnwrap(render.element(identifier: "car-mic"), "No mic target: \(context)")
                XCTAssertGreaterThanOrEqual(
                    mic.frame.height,
                    CarModeMetrics.micHeight,
                    "The voice reply target must stay oversized: \(context)"
                )
                let play = try XCTUnwrap(render.element(identifier: "car-audio-\(entry.id)"), "No playback target: \(context)")
                XCTAssertGreaterThanOrEqual(play.frame.height, CarModeMetrics.minimumActionHeight, context)
            }
        }
    }

    func testVoiceLayerKeepsItsPrimaryActionOversized() async throws {
        let directory = try renderDirectory()
        let entry = try fixtureEntry(summary: questionSummary)
        let phases: [(String, CarModeStore.VoicePhase, String, CGFloat)] = [
            ("recording", .recording(startedAt: Date(timeIntervalSince1970: 1_900_000_000)), "car-voice-finish", 88),
            ("review", .review("Change the demo station to metric only, then re-run the sample checks."), "car-voice-send", 88),
            ("failed", .failed("No speech was found in the recording."), "car-voice-retry", 88),
        ]

        for dynamicType in dynamicTypeSizes {
            let scale = CarModeMetrics.scale(for: dynamicType.swiftUI)
            for (name, phase, identifier, minimum) in phases {
                let layer = CarVoiceCaptureView(
                    phase: phase,
                    agentTitle: entry.pane.displayTitle,
                    workspaceLabel: entry.session.workspace.label,
                    disposition: .prompt,
                    samples: Array(repeating: 0.5, count: 40),
                    scale: scale,
                    isWide: false,
                    confirmsTranscripts: true,
                    finish: {},
                    send: {},
                    retry: {},
                    cancel: {}
                )
                .frame(height: 700)

                let render = await harness.render(layer, width: 393, dynamicType: dynamicType)
                let context = "voice \(name), \(dynamicType.name)"
                try save(render: render, name: "voice-\(name)-\(dynamicType.name)", directory: directory)

                let primary = try XCTUnwrap(render.element(identifier: identifier), "No primary action: \(context)")
                XCTAssertGreaterThanOrEqual(primary.frame.height, minimum, context)
                XCTAssertGreaterThan(primary.frame.width, 200, "The primary action should span the screen: \(context)")
            }
        }
    }

    func testMarkdownAnswerRendersBlocksWithoutLosingTheVoiceTarget() async throws {
        let directory = try renderDirectory()
        for dynamicType in dynamicTypeSizes {
            let scale = CarModeMetrics.scale(for: dynamicType.swiftUI)
            for isWide in [false, true] {
                let entry = try fixtureEntry(summary: markdownSummary)
                let detail = CarAgentDetailView(
                    entry: entry,
                    scale: scale,
                    isWide: isWide,
                    isRecording: false,
                    back: {},
                    play: {},
                    respond: {}
                )
                .frame(height: isWide ? 393 : 700)

                let render = await harness.render(
                    detail,
                    width: isWide ? 852 : 393,
                    dynamicType: dynamicType
                )
                let context = "markdown detail, \(isWide ? "wide" : "portrait"), \(dynamicType.name)"
                try save(render: render, name: "detail-markdown-\(isWide ? "wide" : "portrait")-\(dynamicType.name)", directory: directory)

                XCTAssertTrue(render.drewHierarchy, context)
                let code = try XCTUnwrap(
                    render.element(identifier: "car-md-code"),
                    "The fenced block must render as a code block: \(context)"
                )
                XCTAssertGreaterThan(code.frame.width, 100, "Code block collapsed: \(context)")
                XCTAssertGreaterThanOrEqual(
                    code.frame.height,
                    40,
                    "Code block collapsed: \(context)"
                )
                let mic = try XCTUnwrap(render.element(identifier: "car-mic"), context)
                XCTAssertGreaterThanOrEqual(
                    mic.frame.height,
                    CarModeMetrics.micHeight,
                    "Markdown must not cost the driving-sized reply target: \(context)"
                )
            }
        }
    }

    // MARK: - Assertions

    private func assertTargets(
        _ render: IOSNativeRenderHarness.HostedRender,
        entry: CarModeStore.Entry,
        context: String,
        minimum: CGFloat
    ) throws {
        let audio = try XCTUnwrap(render.element(identifier: "car-audio-\(entry.id)"), "No summary audio target: \(context)")
        let reply = try XCTUnwrap(render.element(identifier: "car-reply-\(entry.id)"), "No reply target: \(context)")
        for (name, frame) in [("audio", audio), ("reply", reply)] {
            XCTAssertGreaterThanOrEqual(
                frame.frame.height,
                minimum,
                "The \(name) target must stay large enough to hit while driving: \(context)"
            )
            XCTAssertGreaterThan(
                frame.frame.width,
                60,
                "The \(name) target is too narrow to hit reliably: \(context)"
            )
        }
    }

    // MARK: - Fixtures

    private var questionSummary: CarAgentSummary {
        CarAgentSummary(
            kind: .question("Waiting for your answer: keep the demo station in metric?"),
            response: "The demo copy is drafted and the sample readings are wired in.",
            asked: "Draft the fictional weather display copy.",
            phase: .idle,
            isBridgeConnected: true
        )
    }

    private var answerSummary: CarAgentSummary {
        CarAgentSummary(
            kind: .answer("The demo export is ready: three fictional books."),
            response: """
            The demo export is ready: three fictional books, each with a one-line note and a suggested reading order.

            The list sorts winter reading first, then the summer collection, and flags the one placeholder title.
            """,
            asked: "Export the example book list as a table I can review.",
            phase: .idle,
            isBridgeConnected: true
        )
    }

    private var workingSummary: CarAgentSummary {
        CarAgentSummary(
            kind: .activity("Running the seed-layout checks · step 4 of 6"),
            response: "The sample planting plan is checked in and the layout checks are running now.",
            asked: "Lay out a sample herb garden and check the planting plan.",
            phase: .working,
            isBridgeConnected: true
        )
    }

    private var markdownSummary: CarAgentSummary {
        CarAgentSummary(
            kind: .answer("The demo export is ready: three fictional books."),
            response: """
            The demo export is ready: **three fictional books**, each with one line of notes.

            ## What is in the export

            - *Winter reading* first, then the summer collection
            - One placeholder title, flagged rather than removed
            - A `reviewed` column that stays empty until you fill it

            ## Suggested order

            | # | Title | Note |
            | --- | --- | --- |
            | 1 | The Sample Almanac | winter |
            | 2 | Fictional Ferns | summer |

            > Nothing was sent anywhere: review the export and I can reshape the columns.

            ```sh
            head -3 reading-list.csv
            ```
            """,
            asked: "Export the example book list as a table I can review.",
            phase: .idle,
            isBridgeConnected: true
        )
    }

    private var cardFixtures: [(String, CarAgentSummary)] {
        [("question", questionSummary), ("answer", answerSummary), ("working", workingSummary)]
    }

    private func fixtureEntry(summary: CarAgentSummary) throws -> CarModeStore.Entry {
        let pane: [String: Any] = [
            "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
            "agent": "Pi", "display_agent": "Pi",
            "title": "Plan a fictitious herb garden for the sample plot",
            "agent_status": "blocked", "last_activity_at": "2030-01-01T12:00:00Z",
            "pi_semantic": ["available": true, "connected": true, "protocolVersion": 1, "sessionId": "session-1"],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "workspace_id": "w1",
            "label": "Garden Planner",
            "panes": [pane],
        ])
        let workspace = try JSONDecoder().decode(HerdrWorkspace.self, from: data).stamped(machineID: "desktop")
        let session = try XCTUnwrap(
            AgentSession.recent(workspaces: [workspace], machines: [], query: "").first
        )
        let player = ResponseAudioPlayer.preview(
            capabilities: ResponseAudioCapabilities(ok: true, available: true, listen: true, tldr: true),
            phase: .idle,
            hasPlayableResponse: summary.hasPlayableResponse
        )
        return CarModeStore.Entry(
            session: session,
            summary: summary,
            connectionState: .live,
            loadedAt: Date(),
            didLoadAudioCapabilities: true,
            audioPlayer: player
        )
    }

    private func renderDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "herdr-car-mode-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(
        render: IOSNativeRenderHarness.HostedRender,
        name: String,
        directory: URL
    ) throws {
        try XCTUnwrap(render.image.pngData()).write(to: directory.appending(path: "\(name).png"))
    }
}
