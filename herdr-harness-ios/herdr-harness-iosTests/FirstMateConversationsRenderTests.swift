import SwiftUI
import XCTest
@testable import herdr_harness_ios

@MainActor
final class FirstMateConversationsRenderTests: XCTestCase {
    private func fixture() async -> HerdrAppModel {
        let defaults = UserDefaults(suiteName: "ConversationsRender.\(UUID())")!
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
                                  userDefaults: defaults, bootstrapMachines: [])
        await model.observeFirstMate()
        return model
    }

    func testConversationScreensAndCappedAccessibility() async throws {
        let model = await fixture()
        for width: CGFloat in [320, 375, 402, 430] {
            for size in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                let view = NavigationStack {
                    FirstMateConversationsScreen(model: model, fleet: model.firstMateFleet,
                        openFeature: { _ in }, openInfo: { _ in }, openLead: { })
                }.frame(height: 840)
                let render = await IOSNativeRenderHarness().render(view, width: width, dynamicType: size)
                XCTAssertTrue(render.drewHierarchy)
                XCTAssertEqual(render.bounds.width, width)
                for identifier in ["conversation-host-control", "conversation-search-control", "conversation-create-control", "conversation-more-control"] {
                    try assertControl(identifier, render: render, width: width)
                }
                let names = render.measurements.filter { $0.identifier?.hasPrefix("row-name-") == true }
                XCTAssertFalse(names.isEmpty, "Real List rows must lay out: \(render.measurementDiagnostics)")
                for value in names {
                    XCTAssertGreaterThan(value.frame.width, 20, render.measurementDiagnostics)
                    XCTAssertGreaterThan(value.frame.height, 12)
                    XCTAssertGreaterThanOrEqual(value.frame.minX, 0)
                    XCTAssertLessThanOrEqual(value.frame.maxX, width + 0.01)
                }
                try save(render, "fmchat-ios-list-\(Int(width))-\(size.name)")
            }
        }
    }

    func testRowsUseCappedMetricsWithoutClippingStatusOrControls() async throws {
        let model = await fixture()
        let rows = Array(model.firstMateFleet.conversations.prefix(5))
        for width: CGFloat in [320, 375, 402, 430] {
            let view = VStack(spacing: 0) {
                ForEach(rows) { row in FirstMateConversationRow(conversation: row, open: {}) }
            }
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground) }
            .herdrFirstMateChrome()
            let capped = await IOSNativeRenderHarness().render(view, width: width, dynamicType: .xxxLarge)
            let requested = await IOSNativeRenderHarness().render(view, width: width, dynamicType: .accessibility3)
            XCTAssertTrue(capped.drewHierarchy && requested.drewHierarchy)
            XCTAssertEqual(capped.fittingSize, requested.fittingSize)
            for row in rows {
                let key = "\(row.machineID)-\(row.featureID)"
                try assertControl("row-control-\(key)", render: requested, width: width)
                let status = try XCTUnwrap(requested.element(identifier: "row-status-\(key)"), requested.measurementDiagnostics)
                let name = try XCTUnwrap(requested.element(identifier: "row-name-\(key)"))
                XCTAssertGreaterThan(status.frame.width, 20)
                XCTAssertLessThanOrEqual(status.frame.maxX, width)
                XCTAssertGreaterThan(name.frame.width, 20)
            }
            try save(requested, "fmchat-ios-rows-\(Int(width))-capped")
        }
    }

    func testBriefingAndSheetsKeepReadableContentAndTouchTargets() async throws {
        let model = await fixture(), fleet = model.firstMateFleet
        let briefing = await IOSNativeRenderHarness().render(
            NavigationStack { FirstMateLeadBriefingScreen(model: model, fleet: fleet, openFeature: { _ in }) }.frame(height: 840),
            width: 320, dynamicType: .accessibility3
        )
        XCTAssertTrue(briefing.drewHierarchy)
        try save(briefing, "fmchat-ios-briefing-320-capped")
        fleet.beginCreating()
        let create = await IOSNativeRenderHarness().render(
            FirstMateCreateSheet(model: model, fleet: fleet, onCreated: { _ in }).frame(height: 1_400),
            width: 320, dynamicType: .accessibility3
        )
        XCTAssertTrue(create.drewHierarchy)
        try assertControl("create-destination-control", render: create, width: 320)
        try assertControl("create-submit-control", render: create, width: 320)
        try save(create, "fmchat-ios-create-320-capped")
        let row = try XCTUnwrap(fleet.conversations.first)
        let request = try XCTUnwrap(FirstMateMobileArchiveRequest.capture(target: FirstMateMobileListPresentation.target(row), fleet: fleet))
        let archive = await IOSNativeRenderHarness().render(
            FirstMateMobileArchiveSheet(model: model, fleet: fleet, request: request).frame(height: 1_200),
            width: 320, dynamicType: .accessibility3
        )
        XCTAssertTrue(archive.drewHierarchy)
        try assertControl("archive-submit-control", render: archive, width: 320)
        try save(archive, "fmchat-ios-archive-320-capped")
    }

    private func assertControl(_ id: String, render: IOSNativeRenderHarness.HostedRender, width: CGFloat) throws {
        let frame = try XCTUnwrap(render.element(identifier: id), render.measurementDiagnostics).frame
        XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.001, id)
        XCTAssertGreaterThanOrEqual(frame.height, 44 - 0.001, id)
        XCTAssertGreaterThanOrEqual(frame.minX, -0.01, id)
        XCTAssertLessThanOrEqual(frame.maxX, width + 0.01, id)
    }
    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-conversations-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
        let attachment = XCTAttachment(image: render.image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print("HERDR_PHASE2_RENDER \(folder.appending(path: name + ".png").path)")
    }
}
