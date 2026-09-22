import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

@MainActor
final class IOSChatSpaceRenderTests: XCTestCase {
    private let harness = IOSNativeRenderHarness()

    func testTimelineRowUsesFullReadingWidthWithoutLeadingRailGutter() async throws {
        let row = PiTimelineRow(
            id: "turn:synthetic|user",
            turnID: "turn:synthetic",
            content: .user(
                PiUserMessage(
                    id: "synthetic-user",
                    text: "A synthetic prompt for deterministic geometry.",
                    timestamp: nil
                )
            ),
            startsTurn: true,
            isFirstInTimeline: true
        )
        let render = await harness.render(
            PiTimelineRowView(row: row, measuresLayout: true)
                .padding(.horizontal, 16),
            width: 320,
            dynamicType: .defaultSize
        )
        let timelineRow = try XCTUnwrap(render.element(identifier: "pi-timeline-row"))
        let content = try XCTUnwrap(render.element(identifier: "pi-timeline-row-content"))

        XCTAssertEqual(timelineRow.frame.minX, 16, accuracy: 0.5)
        XCTAssertEqual(content.frame.minX, timelineRow.frame.minX, accuracy: 0.5)
        XCTAssertEqual(timelineRow.frame.width, 288, accuracy: 0.5)
    }

    func testNavigationTitleStaysOneLineAndRetainsFullMeasuredText() async throws {
        let title = "A deliberately long synthetic pane title that must truncate at the tail"
        for dynamicType in [
            IOSNativeRenderHarness.DynamicTypeFixture.defaultSize,
            .accessibility3,
        ] {
            let render = await harness.render(
                PaneNavigationTitle(title: title),
                width: 180,
                dynamicType: dynamicType
            )
            let measured = try XCTUnwrap(render.element(identifier: "pane-navigation-title"))
            let font = UIFont.preferredFont(
                forTextStyle: .headline,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicType.uiKit)
            )

            XCTAssertEqual(measured.label, title)
            XCTAssertLessThanOrEqual(measured.frame.height, ceil(font.lineHeight) + 2)
            XCTAssertGreaterThanOrEqual(measured.frame.minX, render.bounds.minX - 0.5)
            XCTAssertLessThanOrEqual(measured.frame.maxX, render.bounds.maxX + 0.5)
        }
    }

    func testSyntheticConversationComposesTimelineSelectorsAndNavigation() async throws {
        let user = PiTimelineRow(
            id: "turn:synthetic|user",
            turnID: "turn:synthetic",
            content: .user(
                PiUserMessage(
                    id: "synthetic-user",
                    text: "Keep the app navigator available without duplicating native Back.",
                    timestamp: nil
                )
            ),
            startsTurn: true,
            isFirstInTimeline: true
        )
        let assistant = PiTimelineRow(
            id: "turn:synthetic|assistant",
            turnID: "turn:synthetic",
            content: .output(
                .assistant(
                    PiAssistantBlock(
                        id: "synthetic-assistant",
                        text: "The split detail now opens Chat navigator and preserves native push navigation.",
                        status: .complete,
                        timestamp: nil
                    )
                )
            ),
            startsTurn: false,
            isFirstInTimeline: false
        )
        let render = await harness.render(
            NavigationStack {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            PiTimelineRowView(row: user, measuresLayout: true)
                            PiTimelineRowView(row: assistant)
                        }
                        .padding(16)
                    }

                    PiComposerOptionsBar(
                        configuration: IOSMobileV2ConfigurationFixture.configuration(
                            modelName: "Synthetic Standard",
                            thinkingLevel: PiThinkingLevel.high.rawValue
                        ),
                        responseAudioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                        activateResponseAudio: { _ in }
                    )
                    .padding(12)
                    .background(.ultraThinMaterial)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Open navigator", systemImage: "sidebar.leading") { }
                            .accessibilityIdentifier("sidebar-toggle")
                    }
                    ToolbarItem(placement: .principal) {
                        PaneNavigationTitle(title: "Synthetic conversation")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Pane actions", systemImage: "ellipsis.circle") {
                            Button("Chat") { }
                            Button("Terminal") { }
                        }
                    }
                }
            }
            .frame(height: 700),
            width: 390,
            dynamicType: .defaultSize
        )

        XCTAssertTrue(render.drewHierarchy)
        XCTAssertNotNil(render.element(identifier: "pi-timeline-row-content"))
        XCTAssertNotNil(render.element(identifier: "pi-chat-model"))
        XCTAssertNotNil(render.element(identifier: "pi-chat-thinking"))
        XCTAssertNotNil(render.element(identifier: "pane-navigation-title"))

        let directory = URL(fileURLWithPath: "/tmp/herdr-ios-chat-space-render", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appending(path: "synthetic-conversation.png")
        try XCTUnwrap(render.image.pngData()).write(to: artifact)
        print("HERDR_IOS_CHAT_SPACE_RENDER=\(artifact.path)")
        let attachment = XCTAttachment(image: render.image)
        attachment.name = "synthetic-conversation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLastPromptSheetRendersCopyAndDismissControls() async throws {
        let render = await harness.render(
            LastPromptPeekSheet(
                message: PiUserMessage(
                    id: "synthetic-last-prompt",
                    text: "Summarize the synthetic navigation findings.",
                    timestamp: nil
                ),
                copy: { },
                dismiss: { }
            )
            .frame(height: 320),
            width: 390,
            dynamicType: .defaultSize
        )

        XCTAssertTrue(render.drewHierarchy)
        for identifier in ["pane-last-prompt-copy", "pane-last-prompt-dismiss"] {
            let control = try XCTUnwrap(render.element(identifier: identifier))
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
    }
}
