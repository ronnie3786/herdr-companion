import SwiftUI
import XCTest
@testable import herdr_harness_ios

@MainActor
final class AgentCardCompactRenderTests: XCTestCase {
    func testCompactCardsExpandForLongNamesAndAccessibilityText() async throws {
        let harness = IOSNativeRenderHarness()
        let directory = FileManager.default.temporaryDirectory.appending(path: "herdr-compact-agent-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("HERDR_COMPACT_AGENT_RENDER_DIR=\(directory.path)")

        for width in [CGFloat(320), CGFloat(402)] {
            var standardHeight: CGFloat = 0
            for dynamicType in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                for longName in [false, true] {
                    let session = try session(longName: longName)
                    let render = await harness.render(
                        AgentSessionCard(
                            session: session,
                            connectionState: longName ? .disconnected : .live,
                            isUnread: true,
                            isStarred: true
                        ),
                        width: width,
                        dynamicType: dynamicType
                    )
                    XCTAssertTrue(render.drewHierarchy)
                    XCTAssertLessThanOrEqual(render.fittingSize.width, width)
                    XCTAssertGreaterThanOrEqual(render.fittingSize.height, 44)
                    if dynamicType.name == "default", !longName {
                        standardHeight = render.fittingSize.height
                        XCTAssertLessThan(standardHeight, 100, "Normal cards must retain their compact two-row layout")
                    } else {
                        XCTAssertGreaterThan(render.fittingSize.height, standardHeight, "Long names and large text must grow instead of clipping")
                    }
                    let filename = "card-\(Int(width))-\(dynamicType.name)-\(longName ? "long-offline" : "short").png"
                    try XCTUnwrap(render.image.pngData()).write(to: directory.appending(path: filename))
                }
            }
        }
    }

    private func session(longName: Bool) throws -> AgentSession {
        let pane: [String: Any] = [
            "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
            "agent": "Pi", "display_agent": longName ? "Garden planning assistant" : "Pi",
            "title": longName ? "Review the fictional garden plan and prepare the planting schedule for next spring" : "Plan a fictional garden",
            "agent_status": "blocked", "last_activity_at": "2030-01-01T12:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: ["workspace_id": "w1", "label": "Garden Planner", "panes": [pane]])
        let workspace = try JSONDecoder().decode(HerdrWorkspace.self, from: data)
        return try XCTUnwrap(AgentSession.recent(workspaces: [workspace], machines: [], query: "").first)
    }
}
