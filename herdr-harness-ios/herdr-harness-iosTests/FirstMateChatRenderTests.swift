import SwiftUI
import XCTest
@testable import herdr_harness_ios

@MainActor
final class FirstMateChatRenderTests: XCTestCase {
    private func fixture() async -> HerdrAppModel {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "ChatRender.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        return model
    }
    func testReceiptsChatAndClosedScreen() async throws {
        let model = await fixture(), fleet = model.firstMateFleet
        let target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        XCTAssertTrue(fleet.open(target))
        let store = try XCTUnwrap(fleet.store(for: target))
        let originalReads = fleet.chat.readState
        for width: CGFloat in [320, 402] {
            for size in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                let render = await IOSNativeRenderHarness().render(
                    NavigationStack { FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: true, openInfo: { _, _ in }) }.frame(height: 840),
                    width: width, dynamicType: size)
                XCTAssertTrue(render.drewHierarchy)
                for id in ["chat-back-control", "chat-title-control", "chat-info-control", "chat-more-control", "composer-plus-control", "composer-send-control"] {
                    try assertControl(id, render, width)
                }
                try save(render, "phase3-receipts-\(Int(width))-\(size.name)")
            }
        }
        XCTAssertEqual(fleet.chat.readState, originalReads, "Offscreen rendering must never acknowledge live reads")
        var closed = try XCTUnwrap(store.snapshots[target.featureID]); closed.feature.status = "completed"; store.receive(closed)
        for width: CGFloat in [320, 402] {
            let render = await IOSNativeRenderHarness().render(
                NavigationStack { FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: true, openInfo: { _, _ in }) }.frame(height: 840),
                width: width, dynamicType: .accessibility3)
            XCTAssertNil(render.element(identifier: "composer-send-control"))
            let closedLine = try XCTUnwrap(render.element(identifier: "closed-feature-line"), render.measurementDiagnostics)
            XCTAssertGreaterThan(closedLine.frame.height, 15)
            XCTAssertGreaterThanOrEqual(closedLine.frame.minY, 0)
            XCTAssertLessThanOrEqual(closedLine.frame.maxY, render.bounds.height + 0.01, render.measurementDiagnostics)
            try save(render, "phase3-closed-\(Int(width))-capped")
        }
    }
    func testBriefingReadoutAndComposerStates() async throws {
        let model = await fixture(), fleet = model.firstMateFleet
        let row = try XCTUnwrap(fleet.conversations.first { $0.featureID == "demo-receipts" })
        for width: CGFloat in [320, 402] {
            let briefing = await IOSNativeRenderHarness().render(
                NavigationStack { FirstMateLeadBriefingScreen(model: model, fleet: fleet, openFeature: { _ in }) }.frame(height: 840),
                width: width, dynamicType: .accessibility3)
            try save(briefing, "phase3-briefing-\(Int(width))-capped")
            for focused in [false, true] {
                let composer = await IOSNativeRenderHarness().render(
                    FirstMateMessageComposer(text: .constant(focused ? "A synthetic draft\nwith a second line" : ""),
                        placeholder: "Message Receipt export", canControl: true, isSending: false, send: {}, openDocuments: {}, initiallyFocused: focused)
                        .padding(16).background(HerdrTheme.base), width: width, dynamicType: .accessibility3)
                try assertControl("composer-plus-control", composer, width)
                try assertControl("composer-send-control", composer, width)
                try save(composer, "phase3-composer-\(focused ? "focused" : "idle")-\(Int(width))-capped")
            }
            let readout = await IOSNativeRenderHarness().render(FirstMateFeatureReadout(conversation: row, open: {}).frame(maxWidth: .infinity),
                width: width, dynamicType: .accessibility3)
            XCTAssertTrue(readout.drewHierarchy)
            try save(readout, "phase3-readout-\(Int(width))-capped")
        }
    }
    func testFullLongBubbleRetainsAllContentAtCap() async throws {
        let snapshot = try XCTUnwrap(FirstMateDemo.chatWindowFeatures().first)
        let text = (1...24).map { "Paragraph \($0). This synthetic message remains readable with complete sentences and no line limit." }.joined(separator: "\n\n") + "\n\nEND OF COMPLETE MESSAGE"
        let message = FirstMateMessage(id: "long-reply", featureID: snapshot.feature.id, role: "assistant", text: text, status: "completed", createdAt: "2030-01-01T00:00:00Z")
        let view = FirstMateChatBubble(row: .init(message: message, speaker: .firstMate, isFirstInGroup: true, isLastInGroup: true),
            snapshot: snapshot, maximumWidth: 236, skimState: SkimReadingState(), catalog: .init(entries: []),
            sendReply: { _ in }, presentationChanged: { _, _ in }).herdrFirstMateChrome()
        let capped = await IOSNativeRenderHarness().render(view, width: 320, dynamicType: .xxxLarge)
        let requested = await IOSNativeRenderHarness().render(view, width: 320, dynamicType: .accessibility3)
        XCTAssertEqual(capped.fittingSize, requested.fittingSize)
        XCTAssertGreaterThan(requested.fittingSize.height, 3_000, "The body must expand rather than truncate")
        try save(requested, "phase3-long-message-320-capped")
    }
    private func assertControl(_ id: String, _ render: IOSNativeRenderHarness.HostedRender, _ width: CGFloat) throws {
        let frame = try XCTUnwrap(render.element(identifier: id), render.measurementDiagnostics).frame
        XCTAssertGreaterThanOrEqual(frame.width, 43.99, id); XCTAssertGreaterThanOrEqual(frame.height, 43.99, id)
        XCTAssertGreaterThanOrEqual(frame.minX, -0.01, id); XCTAssertLessThanOrEqual(frame.maxX, width + 0.01, id)
    }
    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-chat-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
        let attachment = XCTAttachment(image: render.image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print("HERDR_PHASE3_RENDER \(folder.appending(path: name + ".png").path)")
    }
}
