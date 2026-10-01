import SwiftUI
import XCTest
@testable import herdr_harness_ios

@MainActor
final class FirstMateInfoRenderTests: XCTestCase {
    private func fixture() async -> HerdrAppModel {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "InfoRender.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        return model
    }

    func testEveryInfoTabAndSavedResourcesAtPhoneWidths() async throws {
        let model = await fixture(), fleet = model.firstMateFleet
        let target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        XCTAssertTrue(fleet.open(target))
        let store = try XCTUnwrap(fleet.store(for: target))
        let snapshot = try XCTUnwrap(store.snapshot)
        for width: CGFloat in [320, 402] {
            for size in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                for tab in [FirstMateInspector.overview, .agents, .documents, .workflow] {
                    store.inspector = tab
                    let render = await IOSNativeRenderHarness().render(
                        NavigationStack {
                            FirstMateInfoScreen(model: model, fleet: fleet, store: store, target: target,
                                assignmentID: snapshot.assignments.first?.id)
                        }.frame(height: 840), width: width, dynamicType: size)
                    XCTAssertTrue(render.drewHierarchy)
                    let footer = try XCTUnwrap(render.element(identifier: "info-sync-footer"), render.measurementDiagnostics)
                    XCTAssertGreaterThanOrEqual(footer.frame.height, 36)
                    XCTAssertLessThanOrEqual(footer.frame.maxY, render.bounds.height + 0.01)
                    let selected = try XCTUnwrap(render.element(identifier: "info-tab-\(tab.id)"), render.measurementDiagnostics)
                    XCTAssertGreaterThanOrEqual(selected.frame.width, 43.99)
                    XCTAssertGreaterThanOrEqual(selected.frame.height, 43.99)
                    try save(render, "phase6-info-\(tab.id)-\(Int(width))-\(size.name)")
                }
            }
            let document = try XCTUnwrap(snapshot.documents.first)
            let agent = try XCTUnwrap(snapshot.assignments.first { $0.nativeSessionID != nil })
            for resource in [FirstMateResource.document(document), .session(agent)] {
                await store.open(resource)
                let render = await IOSNativeRenderHarness().render(
                    FirstMateResourceSheet(store: store, resource: resource).frame(height: 840),
                    width: width, dynamicType: .accessibility3)
                XCTAssertTrue(render.drewHierarchy)
                // Close is the system glass close button (a UIKit bar item, so it
                // has no SwiftUI anchor). HerdrFirstMatePolishUITests reaches and
                // taps `first-mate-resource-close` on the real sheet.
                try save(render, "phase6-\(resource.nativeSessionID == nil ? "document" : "session")-\(Int(width))-capped")
                store.closeResource()
            }
        }
    }

    /// Landscape docks the inspector beside the list and chat; portrait keeps
    /// two panes until the inspector is asked for (FirstMateIPadLayoutTests).
    func testIPadHasThreeNonoverlappingColumnsAt1024And1366() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Run on the dedicated iPad simulator") }
        let model = await fixture(), fleet = model.firstMateFleet
        model.selectedTab = .firstMate
        let target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        XCTAssertTrue(fleet.open(target))
        let store = try XCTUnwrap(fleet.store(for: target))
        store.draft = "Retained synthetic iPad draft"
        for width: CGFloat in [1024, 1366] {
            let render = await IOSNativeRenderHarness().render(
                FirstMateWorkspaceView(model: model, fleet: fleet)
                    .environment(\.horizontalSizeClass, .regular).frame(height: width == 1024 ? 1366 : 1024),
                width: width, dynamicType: .accessibility3)
            XCTAssertTrue(render.drewHierarchy)
            let sidebar = try XCTUnwrap(render.element(identifier: "first-mate-sidebar-column"), render.measurementDiagnostics).frame
            let chat = try XCTUnwrap(render.element(identifier: "first-mate-chat-column"), render.measurementDiagnostics).frame
            XCTAssertGreaterThanOrEqual(sidebar.width, 83)
            XCTAssertGreaterThanOrEqual(chat.width, 299)
            XCTAssertGreaterThanOrEqual(sidebar.minX, -1)
            XCTAssertLessThanOrEqual(sidebar.maxX, chat.minX + 1)
            if width == 1366 {
                let info = try XCTUnwrap(render.element(identifier: "first-mate-info-column"), render.measurementDiagnostics).frame
                XCTAssertGreaterThanOrEqual(info.width, 279)
                XCTAssertLessThanOrEqual(chat.maxX, info.minX + 1)
                XCTAssertLessThanOrEqual(info.maxX, width + 1)
            } else {
                XCTAssertNil(render.element(identifier: "first-mate-info-column"), "Portrait opens without the inspector")
                XCTAssertLessThanOrEqual(chat.maxX, width + 1)
            }
            XCTAssertEqual(fleet.selectedTarget, target)
            XCTAssertEqual(store.draft, "Retained synthetic iPad draft")
            print("HERDR_IPAD_COLUMNS width=\(width) sidebar=\(sidebar) chat=\(chat)")
            try save(render, "phase6-ipad-\(Int(width))-capped")
        }
    }

    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-info-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
        let attachment = XCTAttachment(image: render.image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
