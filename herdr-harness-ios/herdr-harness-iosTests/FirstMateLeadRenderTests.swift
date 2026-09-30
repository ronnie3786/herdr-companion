import SwiftUI
import XCTest
@testable import herdr_harness_ios

@MainActor
final class FirstMateLeadRenderTests: XCTestCase {
    func testLeadChatOverviewAndOfflineHeaderAtPhoneWidthsAndCap() async throws {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "LeadRender.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        let fleet = model.firstMateFleet
        fleet.chat.pin("demo1")
        for offline in [false, true] {
            if offline { fleet.failDemoLeadPoll(); fleet.failDemoLeadPoll() }
            let opened = await fleet.chat.openLead(fleet: fleet)
            let target = try XCTUnwrap(opened)
            let store = try XCTUnwrap(fleet.store(for: target))
            let reads = fleet.chat.readState
            for width: CGFloat in [320, 402] {
                for size in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                    let chat = await IOSNativeRenderHarness().render(
                        NavigationStack {
                            FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: true,
                                openInfo: { _, _ in }, followsLeadChoice: true)
                        }.frame(height: 840), width: width, dynamicType: size)
                    XCTAssertTrue(chat.drewHierarchy)
                    for id in ["chat-back-control", "lead-machine-control", "chat-info-control", "chat-more-control", "composer-microphone-control"] {
                        let frame = try XCTUnwrap(chat.element(identifier: id), chat.measurementDiagnostics).frame
                        XCTAssertGreaterThanOrEqual(frame.width, 43.99, id); XCTAssertGreaterThanOrEqual(frame.height, 43.99, id)
                        XCTAssertGreaterThanOrEqual(frame.minX, -0.01, id); XCTAssertLessThanOrEqual(frame.maxX, width + 0.01, id)
                        XCTAssertLessThanOrEqual(frame.maxY, chat.bounds.height + 0.01, id)
                    }
                    try save(chat, "fmchat-ios-\(offline ? "offline-header" : "chat-lead")-\(Int(width))-\(size.name)")
                    if !offline {
                        let info = await IOSNativeRenderHarness().render(
                            NavigationStack { FirstMateInfoScreen(model: model, fleet: fleet, store: store, target: target) }.frame(height: 840),
                            width: width, dynamicType: size)
                        XCTAssertTrue(info.drewHierarchy)
                        try save(info, "fmchat-ios-info-lead-\(Int(width))-\(size.name)")
                    }
                }
            }
            XCTAssertEqual(fleet.chat.readState, reads, "Native render hosts must not acknowledge messages")
        }
    }
    func testOlderHostBriefingAtPhoneWidthsAndCap() async throws {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "OlderLeadRender.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        // The UI suite supplies actual older-capability hosts; this native render
        // measures the fallback view independently, without dispatching a lead.
        for width: CGFloat in [320, 402] {
            for size in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                let render = await IOSNativeRenderHarness().render(
                    NavigationStack { FirstMateLeadBriefingScreen(model: model, fleet: model.firstMateFleet, openFeature: { _ in }) }.frame(height: 840),
                    width: width, dynamicType: size)
                XCTAssertTrue(render.drewHierarchy)
                try save(render, "fmchat-ios-older-briefing-\(Int(width))-\(size.name)")
            }
        }
    }
    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-lead-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
        let attachment = XCTAttachment(image: render.image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
