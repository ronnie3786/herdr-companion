import SwiftUI
import XCTest
@testable import herdr_harness_ios

/// Renders the First Mate Git cover from the synthetic demo at iPad
/// landscape and portrait (13″) and iPhone width, and checks its geometry:
/// the list column beside the diff on iPad, list first on iPhone, and 44 pt
/// targets. PNGs land in $HERDR_IOS_RENDER_DIR.
@MainActor
final class FirstMateGitRenderTests: XCTestCase {
    private let receipts = FirstMateGitTarget(feature: .init(machineID: "demo1", featureID: "demo-receipts"),
                                              featureTitle: "Receipt export")

    private func model() -> HerdrAppModel {
        HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
                      userDefaults: UserDefaults(suiteName: "GitRender.\(UUID())")!, bootstrapMachines: [])
    }

    private func loadedStore(_ target: FirstMateGitTarget) async -> FirstMateGitStore {
        let store = FirstMateGitStore(pinnedCheckoutID: target.workspaceID, commitSHA: target.commitSHA)
        await store.start(backend: FirstMateGitDemoBackend(featureID: target.feature.featureID, featureTitle: target.featureTitle))
        await store.prefetchCounts()
        return store
    }

    private func render(
        _ target: FirstMateGitTarget, store: FirstMateGitStore, pushed: FirstMateGitSelection? = nil,
        width: CGFloat, height: CGFloat, sizeClass: UserInterfaceSizeClass,
        dynamicType: IOSNativeRenderHarness.DynamicTypeFixture = .defaultSize
    ) async -> IOSNativeRenderHarness.HostedRender {
        await IOSNativeRenderHarness().render(
            FirstMateGitScreen(target: target, model: model(), store: store, pushed: pushed)
                .environment(\.horizontalSizeClass, sizeClass)
                .frame(height: height),
            width: width, dynamicType: dynamicType)
    }

    func testIPadLandscapeAndPortraitShowListBesideDiff() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Run on the dedicated iPad simulator") }
        for (width, height, name) in [(CGFloat(1376), CGFloat(1032), "landscape"), (1032, 1376, "portrait")] {
            let store = await loadedStore(receipts)
            let render = await render(receipts, store: store, width: width, height: height, sizeClass: .regular)
            XCTAssertTrue(render.drewHierarchy)
            let list = try XCTUnwrap(render.element(identifier: "first-mate-git-list-column"), render.measurementDiagnostics).frame
            let detail = try XCTUnwrap(render.element(identifier: "first-mate-git-detail-column"), render.measurementDiagnostics).frame
            let header = try XCTUnwrap(render.element(identifier: "first-mate-git-header"), render.measurementDiagnostics).frame
            XCTAssertEqual(list.width, max(300, width * 0.34), accuracy: 1)
            XCTAssertLessThanOrEqual(list.maxX, detail.minX + 1)
            XCTAssertEqual(detail.maxX, width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(list.minY, header.maxY - 1)
            XCTAssertGreaterThanOrEqual(header.height, 63.5)
            for id in ["first-mate-git-done", "first-mate-git-refresh", "first-mate-git-checkout-picker",
                       "first-mate-git-stage-unstaged-Sources/Receipts/ReceiptExporter.swift",
                       "first-mate-git-stage-staged-Sources/Receipts/ExportButton.swift",
                       "first-mate-git-detail-stage"] {
                let frame = try XCTUnwrap(render.element(identifier: id), "\(id)\n" + render.measurementDiagnostics).frame
                XCTAssertGreaterThanOrEqual(frame.height, 43.99, id)
                XCTAssertGreaterThanOrEqual(frame.width, 43.99, id)
            }
            let row = try XCTUnwrap(render.element(identifier: "first-mate-git-file-unstaged-Sources/Receipts/ReceiptExporter.swift"))
            XCTAssertGreaterThanOrEqual(row.frame.height, 49.5)
            XCTAssertLessThanOrEqual(row.frame.maxX, list.maxX)
            XCTAssertNotNil(render.element(identifier: "first-mate-git-commit-c81d5e9"))
            try save(render, "git-ipad-\(name)")
        }
    }

    func testIPadCommitReceiptAndCleanCheckout() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Run on the dedicated iPad simulator") }
        var receipt = receipts
        receipt.workspaceID = "demo-worker"
        receipt.commitSHA = "7b2e0d4a9c1f3e22"
        let store = await loadedStore(receipt)
        XCTAssertEqual(store.selection, .commit(hash: "7b2e0d4"))
        let commit = await render(receipt, store: store, width: 1376, height: 1032, sizeClass: .regular)
        XCTAssertTrue(commit.drewHierarchy)
        // Pinned to one checkout: no picker.
        XCTAssertNil(commit.element(identifier: "first-mate-git-checkout-picker"))
        try save(commit, "git-ipad-commit-receipt")

        let search = FirstMateGitTarget(feature: .init(machineID: "demo1", featureID: "demo-search"), featureTitle: "Review search")
        let clean = await render(search, store: await loadedStore(search), width: 1032, height: 1376, sizeClass: .regular)
        XCTAssertTrue(clean.drewHierarchy)
        XCTAssertNotNil(clean.element(identifier: "first-mate-git-commit-6a2d9e1"))
        try save(clean, "git-ipad-clean")

        var unknown = receipts
        unknown.workspaceID = "demo-worker"
        unknown.commitSHA = "ffffeeee11112222"
        let missing = await render(unknown, store: await loadedStore(unknown), width: 1376, height: 1032, sizeClass: .regular)
        try save(missing, "git-ipad-commit-not-found")
    }

    func testStatesRender() async throws {
        let unsupported = FirstMateGitStore()
        await unsupported.start(backend: UnsupportedGitBackend())
        XCTAssertEqual(unsupported.phase, .unsupported)
        let render = await render(receipts, store: unsupported, width: 1032, height: 700, sizeClass: .regular)
        XCTAssertTrue(render.drewHierarchy)
        XCTAssertNil(render.element(identifier: "first-mate-git-list-column"))
        try save(render, "git-state-unsupported")
    }

    func testIPhoneShowsListFirstAndPushesTheDiff() async throws {
        let store = await loadedStore(receipts)
        let list = await render(receipts, store: store, width: 402, height: 874, sizeClass: .compact)
        XCTAssertTrue(list.drewHierarchy)
        let column = try XCTUnwrap(list.element(identifier: "first-mate-git-list-column"), list.measurementDiagnostics).frame
        XCTAssertEqual(column.width, 402, accuracy: 1)
        XCTAssertNil(list.element(identifier: "first-mate-git-detail-column"))
        for id in ["first-mate-git-done", "first-mate-git-refresh", "first-mate-git-checkout-picker",
                   "first-mate-git-stage-unstaged-Tests/ReceiptExportUITests.swift"] {
            let frame = try XCTUnwrap(list.element(identifier: id), "\(id)\n" + list.measurementDiagnostics).frame
            XCTAssertGreaterThanOrEqual(min(frame.width, frame.height), 43.99, id)
            XCTAssertLessThanOrEqual(frame.maxX, 402.5, id)
        }
        try save(list, "git-iphone-list")

        let pushedFile = FirstMateGitSelection.file(path: "Sources/Receipts/ReceiptExporter.swift", section: .unstaged)
        store.select(pushedFile)
        await store.loadSelectionContent()
        let diff = await render(receipts, store: store, pushed: pushedFile, width: 402, height: 874, sizeClass: .compact)
        XCTAssertTrue(diff.drewHierarchy)
        XCTAssertNotNil(diff.element(identifier: "first-mate-git-detail-column"), diff.measurementDiagnostics)
        let stage = try XCTUnwrap(diff.element(identifier: "first-mate-git-detail-stage"), diff.measurementDiagnostics).frame
        XCTAssertGreaterThanOrEqual(stage.height, 43.99)
        XCTAssertLessThanOrEqual(stage.maxX, 402.5)
        try save(diff, "git-iphone-diff")

        var receipt = receipts
        receipt.workspaceID = "demo-worker"
        receipt.commitSHA = "a3f9c21e5b7d4c10"
        let commit = await render(receipt, store: await loadedStore(receipt), width: 402, height: 874, sizeClass: .compact)
        XCTAssertNotNil(commit.element(identifier: "first-mate-git-detail-column"), commit.measurementDiagnostics)
        try save(commit, "git-iphone-commit")

        let large = await render(receipts, store: await loadedStore(receipts), width: 402, height: 874, sizeClass: .compact,
                                 dynamicType: .accessibility3)
        XCTAssertTrue(large.drewHierarchy)
        try save(large, "git-iphone-list-accessibility3")
    }

    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-git-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
        let attachment = XCTAttachment(image: render.image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private struct UnsupportedGitBackend: FirstMateGitBackend {
    func supportsGit() async throws -> Bool { false }
    func checkouts() async throws -> FirstMateGitCheckoutCatalog { throw APIError.invalidResponse }
    func status(workspace: String) async throws -> FirstMateGitStatus { throw APIError.invalidResponse }
    func diff(workspace: String, file: String, section: GitFileSection, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        throw APIError.invalidResponse
    }
    func stage(workspace: String, file: String, expectedRoot: String) async throws { throw APIError.invalidResponse }
    func unstage(workspace: String, file: String, expectedRoot: String) async throws { throw APIError.invalidResponse }
    func commitFiles(workspace: String, hash: String, expectedRoot: String) async throws -> FirstMateGitCommitFilesResponse {
        throw APIError.invalidResponse
    }
    func commitDiff(workspace: String, hash: String, file: String, expectedRoot: String) async throws -> FirstMateGitDiffResponse {
        throw APIError.invalidResponse
    }
}
