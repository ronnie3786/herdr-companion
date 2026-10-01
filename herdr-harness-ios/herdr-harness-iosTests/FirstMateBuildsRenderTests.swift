import SwiftUI
import XCTest
@testable import herdr_harness_ios

/// Demo-mode renders of the Builds card, the stage chips and the full-screen
/// simulator. Everything is synthetic; nothing contacts a hub or companion.
@MainActor
final class FirstMateBuildsRenderTests: XCTestCase {
    private func fixture() async -> HerdrAppModel {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "BuildsRender.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        return model
    }

    private func context(_ model: HerdrAppModel, _ featureID: String) throws -> (FirstMateInspectorContext, FirstMateSnapshot) {
        let target = FirstMateFeatureTarget(machineID: "demo1", featureID: featureID)
        XCTAssertTrue(model.firstMateFleet.open(target))
        let snapshot = try XCTUnwrap(model.firstMateFleet.store(for: target)?.snapshot)
        return (FirstMateInspectorContext(model: model, target: target, featureTitle: snapshot.feature.title, openGit: { _ in }), snapshot)
    }

    func testBuildsCardAtIPadInspectorAndIPhoneWidths() async throws {
        let model = await fixture()
        for featureID in ["demo-receipts", "demo-search"] {
            let (context, snapshot) = try context(model, featureID)
            for width: CGFloat in [380, 402] {
                for size in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                    let render = await IOSNativeRenderHarness().render(
                        VStack(alignment: .leading, spacing: 12) {
                            FirstMateBuildsSection(snapshot: snapshot)
                            ForEach(snapshot.visits) { visit in
                                HStack(spacing: 6) {
                                    Text(visit.title).herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                                    FirstMateSimulatorVisitChip(visitID: visit.id)
                                }
                            }
                        }
                        .padding(16)
                        .environment(\.firstMateInspectorContext, context),
                        width: width, dynamicType: size, background: .dusk)
                    XCTAssertTrue(render.drewHierarchy)
                    let card = try XCTUnwrap(render.element(identifier: "first-mate-builds-section"), render.measurementDiagnostics)
                    XCTAssertGreaterThanOrEqual(card.frame.minX, 15)
                    XCTAssertLessThanOrEqual(card.frame.maxX, width - 15)
                    for hub in render.measurements where hub.identifier?.hasPrefix("first-mate-build-install-") == true
                        || hub.identifier?.hasPrefix("first-mate-simulator-open-") == true
                        || hub.identifier?.hasPrefix("first-mate-simulator-visit-") == true {
                        XCTAssertGreaterThanOrEqual(hub.frame.height, 43.99, "\(hub.identifier ?? "") is too small to tap")
                        XCTAssertLessThanOrEqual(hub.frame.maxX, width - 15, "\(hub.identifier ?? "") runs off the card")
                    }
                    if featureID == "demo-receipts" {
                        XCTAssertNotNil(render.element(identifier: "first-mate-build-install-demo-hub-receipts-118"))
                        XCTAssertNotNil(render.element(identifier: "first-mate-simulator-open-demo-sim-receipts-118"))
                        XCTAssertNotNil(render.element(identifier: "first-mate-simulator-open-demo-sim-receipts-qa2"))
                        let qa = try XCTUnwrap(snapshot.visits.last { $0.stageKey == "proof" })
                        XCTAssertNotNil(render.element(identifier: "first-mate-simulator-visit-\(qa.id)"), render.measurementDiagnostics)
                    }
                    try save(render, "builds-\(featureID)-\(Int(width))-\(size.name)")
                }
            }
        }
    }

    func testBuildsCardIsHiddenWithoutBuilds() async throws {
        let model = await fixture()
        let (context, snapshot) = try context(model, "demo-widgets")
        let render = await IOSNativeRenderHarness().render(
            VStack(alignment: .leading, spacing: 0) {
                Text("Above").frame(height: 20)
                FirstMateBuildsSection(snapshot: snapshot)
                ForEach(snapshot.visits) { FirstMateSimulatorVisitChip(visitID: $0.id) }
                Text("Below").frame(height: 20)
            }
            .environment(\.firstMateInspectorContext, context),
            width: 380, dynamicType: .defaultSize)
        XCTAssertNil(render.element(identifier: "first-mate-builds-section"))
        XCTAssertEqual(render.bounds.height, 40, accuracy: 0.5)
    }

    func testSimulatorCoverOnIPadLandscapeAndIPhone() async throws {
        let model = await fixture()
        let (_, search) = try context(model, "demo-search")
        let (_, receipts) = try context(model, "demo-receipts")
        let searchBuild = try XCTUnwrap(FirstMateBuildsDemo.content(for: search, machineName: "desktop")?.simulator.first)
        let receiptsBuild = try XCTUnwrap(FirstMateBuildsDemo.content(for: receipts, machineName: "desktop")?.simulator.first)

        func session(_ build: FirstMateSimulatorBuild, _ step: String? = nil) -> FirstMateSimulatorSession {
            let session = FirstMateSimulatorSession(
                target: FirstMateSimulatorWindowTarget(machineID: "demo1", featureID: build.featureID, buildID: build.id),
                machineName: "desktop", api: nil, isDemo: true)
            session.presentDemo(build: build, feature: nil,
                                screen: FirstMateSimulatorDemoAppScreen.image(FirstMateBuildsDemo.screenKind(for: build)),
                                startingAt: step)
            return session
        }
        let stopped = session(receiptsBuild)
        stopped.presentDemoStopped()
        let states: [(String, FirstMateSimulatorSession)] = [
            ("running", session(searchBuild)),
            ("booting", session(receiptsBuild, "booting")),
            ("installing", session(receiptsBuild, "installing")),
            ("stopped", stopped),
        ]
        let layouts: [(String, CGFloat, CGFloat, UserInterfaceSizeClass)] = [
            ("ipad-landscape", 1366, 1024, .regular),
            ("ipad-portrait", 1024, 1366, .regular),
            ("iphone", 402, 874, .compact),
        ]
        for (layout, width, height, sizeClass) in layouts {
            for (name, session) in states {
                let render = await IOSNativeRenderHarness().render(
                    FirstMateSimulatorCoverContent(session: session)
                        .environment(\.horizontalSizeClass, sizeClass)
                        .frame(height: height),
                    width: width, dynamicType: .defaultSize)
                XCTAssertTrue(render.drewHierarchy)
                let bar = try XCTUnwrap(render.element(identifier: "first-mate-simulator-bar"), render.measurementDiagnostics)
                let stage = try XCTUnwrap(render.element(identifier: "first-mate-simulator-stage"), render.measurementDiagnostics)
                let controls = try XCTUnwrap(render.element(identifier: "first-mate-simulator-controls"), render.measurementDiagnostics)
                XCTAssertLessThanOrEqual(bar.frame.maxX, width + 0.5)
                XCTAssertLessThanOrEqual(bar.frame.maxY, stage.frame.minY + 0.5)
                XCTAssertLessThanOrEqual(stage.frame.maxY, controls.frame.minY + 0.5)
                XCTAssertGreaterThan(stage.frame.height, height * 0.55, "\(layout) \(name): the simulator should fill the cover")
                XCTAssertGreaterThanOrEqual(controls.frame.height, 43.99)
                XCTAssertLessThanOrEqual(controls.frame.maxX, width)
                try save(render, "simulator-cover-\(layout)-\(name)")
            }
        }
    }

    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-builds-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
        let attachment = XCTAttachment(image: render.image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
