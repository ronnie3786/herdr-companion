import SwiftUI
import XCTest
@testable import herdr_harness_ios

/// The iPad First Mates layout: chat first, the list folding to a rail, and
/// the inspector on demand (docked in landscape, floating in portrait).
final class FirstMateIPadLayoutTests: XCTestCase {
    private let landscape13 = CGSize(width: 1376, height: 1032)
    private let portrait13 = CGSize(width: 1032, height: 1376)
    private let landscape11 = CGSize(width: 1210, height: 834)
    private let portrait11 = CGSize(width: 834, height: 1210)

    func testLandscapeDocksTheInspectorBesideTheFullList() {
        let layout = FirstMateIPadLayout.resolve(size: landscape13, inspectorOpen: nil, list: nil, pinned: false)
        XCTAssertEqual(layout.inspector, .docked)
        XCTAssertFalse(layout.showsRail)
        XCTAssertEqual(layout.leadingWidth, 360)
        XCTAssertEqual(layout.inspectorWidth, 380)
        XCTAssertGreaterThanOrEqual(landscape13.width - layout.leadingWidth - layout.dockedInspectorWidth, FirstMateIPadLayout.minimumChatWidth)
    }

    func testSmallerLandscapeFoldsTheListSoTheChatKeepsItsWidth() {
        let layout = FirstMateIPadLayout.resolve(size: landscape11, inspectorOpen: nil, list: nil, pinned: false)
        XCTAssertEqual(layout.inspector, .docked)
        XCTAssertTrue(layout.showsRail)
        XCTAssertEqual(layout.leadingWidth, FirstMateIPadLayout.railWidth)
        let closed = FirstMateIPadLayout.resolve(size: landscape11, inspectorOpen: false, list: nil, pinned: false)
        XCTAssertFalse(closed.showsRail, "Closing the inspector gives the list back")
    }

    func testPortraitOpensWithoutTheInspectorAndFloatsItOnDemand() {
        let closed = FirstMateIPadLayout.resolve(size: portrait13, inspectorOpen: nil, list: nil, pinned: false)
        XCTAssertEqual(closed.inspector, .hidden)
        XCTAssertFalse(closed.showsRail)
        let open = FirstMateIPadLayout.resolve(size: portrait13, inspectorOpen: true, list: nil, pinned: false)
        XCTAssertEqual(open.inspector, .floating)
        XCTAssertFalse(open.showsRail, "A floating inspector doesn't take the list's room")
        XCTAssertEqual(open.inspectorWidth, 400)
        XCTAssertTrue(open.canPin)
    }

    func testPinningInPortraitDocksTheInspectorAndFoldsTheList() {
        let pinned = FirstMateIPadLayout.resolve(size: portrait13, inspectorOpen: true, list: nil, pinned: true)
        XCTAssertEqual(pinned.inspector, .docked)
        XCTAssertTrue(pinned.showsRail)
        XCTAssertFalse(FirstMateIPadLayout.resolve(size: portrait11, inspectorOpen: true, list: nil, pinned: true).canPin,
                       "The 11-inch portrait is too narrow to dock beside the chat")
        XCTAssertEqual(FirstMateIPadLayout.resolve(size: portrait11, inspectorOpen: true, list: nil, pinned: true).inspector, .floating)
    }

    func testAnExplicitFullListFloatsAnInspectorThatWouldCrushTheChat() {
        let layout = FirstMateIPadLayout.resolve(size: landscape11, inspectorOpen: true, list: .full, pinned: false)
        XCTAssertFalse(layout.showsRail)
        XCTAssertEqual(layout.inspector, .docked, "1210 − 336 − 360 still leaves the chat 514 pt")
        let narrow = FirstMateIPadLayout.resolve(size: CGSize(width: 1100, height: 820), inspectorOpen: true, list: .full, pinned: false)
        XCTAssertEqual(narrow.inspector, .floating)
    }

    func testFoldersSplitTheListByWhoTheWorkIsWaitingOn() {
        XCTAssertTrue(FirstMateListFolder.needsYou.includes(row(.blocked)))
        XCTAssertTrue(FirstMateListFolder.needsYou.includes(row(.ready)))
        XCTAssertFalse(FirstMateListFolder.needsYou.includes(row(.working)))
        XCTAssertTrue(FirstMateListFolder.moving.includes(row(.working)))
        XCTAssertTrue(FirstMateListFolder.moving.includes(row(.idle)))
        XCTAssertFalse(FirstMateListFolder.moving.includes(row(.done)))
        XCTAssertTrue(FirstMateListFolder.done.includes(row(.done)))
        XCTAssertTrue(FirstMateHudStatus.allCases.allSatisfy { FirstMateListFolder.all.includes(row($0)) })
    }

    func testCommitReceiptsListUniqueCommitsAndEndOnTheTerminalOne() {
        let first = FirstMateVisitCommit(sha: "aaa1111", subject: "First", committedAt: "2026-01-01T10:00:00Z")
        let second = FirstMateVisitCommit(sha: "bbb2222", subject: "Second", committedAt: "2026-01-01T11:00:00Z")
        let visit = FirstMateVisit(id: "v", featureID: "f", stageKey: "implement", title: "Build", status: "completed", revision: 1,
            gitEvidence: [
                .init(workspaceID: "w1", startSHA: nil, endSHA: "aaa1111", status: "captured", commits: [first], truncated: false),
                .init(workspaceID: "w2", startSHA: nil, endSHA: "bbb2222", status: "captured", commits: [second, first], truncated: false),
            ])
        let (all, latest) = FirstMateVisitCommits.entries(visit)
        XCTAssertEqual(all.map(\.commit.sha), ["aaa1111", "bbb2222"])
        XCTAssertEqual(latest?.commit.sha, "bbb2222")
        XCTAssertEqual(latest?.workspaceID, "w2")
        XCTAssertNil(FirstMateVisitCommits.entries(FirstMateVisit(id: "x", featureID: "f", stageKey: "plan", title: "Plan",
                                                                   status: "completed", revision: 1)).latest)
    }

    private func row(_ status: FirstMateHudStatus) -> FirstMateConversation {
        FirstMateConversation(id: .init(machineID: "m", featureID: "f-\(status.rawValue)"), machineID: "m", machineName: "Mac",
            featureID: "f-\(status.rawValue)", title: "Feature", label: "Feature", isUserNamed: false, emoji: "🧪", isUserEmoji: false,
            hudStatus: status, featureStatus: "running", stepIndex: 1, stepFraction: 0.5, now: nil, previewText: "",
            previewIsFromUser: false, isWorkingOnReply: false, activityAt: nil, latestFirstMateMessageID: nil, isUnread: false, isArchived: false)
    }
}

/// Renders of the iPad workspace and the iPhone chat bar in demo mode.
@MainActor
final class FirstMateIPadRenderTests: XCTestCase {
    private func fixture() async -> HerdrAppModel {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "IPadRender.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        return model
    }

    private func workspace(_ model: HerdrAppModel, size: CGSize) async -> IOSNativeRenderHarness.HostedRender {
        await IOSNativeRenderHarness().render(
            FirstMateWorkspaceView(model: model, fleet: model.firstMateFleet)
                .environment(\.horizontalSizeClass, .regular).frame(height: size.height),
            width: size.width, dynamicType: .defaultSize, background: .dusk)
    }

    func testLandscapeShowsListChatAndDockedInspectorWithoutOverlap() async throws {
        let model = await fixture(), fleet = model.firstMateFleet
        model.selectedTab = .firstMate
        let target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        XCTAssertTrue(fleet.open(target))
        for size in [CGSize(width: 1376, height: 1032), CGSize(width: 1210, height: 834)] {
            let render = await workspace(model, size: size)
            XCTAssertTrue(render.drewHierarchy)
            let list = try XCTUnwrap(render.element(identifier: "first-mate-sidebar-column"), render.measurementDiagnostics).frame
            let chat = try XCTUnwrap(render.element(identifier: "first-mate-chat-column"), render.measurementDiagnostics).frame
            let info = try XCTUnwrap(render.element(identifier: "first-mate-info-column"), render.measurementDiagnostics).frame
            XCTAssertLessThanOrEqual(list.maxX, chat.minX + 1)
            XCTAssertLessThanOrEqual(chat.maxX, info.minX + 1)
            XCTAssertGreaterThanOrEqual(chat.width, FirstMateIPadLayout.minimumChatWidth - 1)
            try assertChatBarOrder(render)
            try save(render, "a2-ipad-landscape-\(Int(size.width))")
        }
    }

    func testPortraitKeepsTwoPanesUntilTheInspectorIsAskedFor() async throws {
        let model = await fixture(), fleet = model.firstMateFleet
        model.selectedTab = .firstMate
        XCTAssertTrue(fleet.open(FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")))
        let render = await workspace(model, size: CGSize(width: 1032, height: 1376))
        XCTAssertTrue(render.drewHierarchy)
        XCTAssertNil(render.element(identifier: "first-mate-info-column"), "Portrait opens without the inspector")
        let chat = try XCTUnwrap(render.element(identifier: "first-mate-chat-column"), render.measurementDiagnostics).frame
        XCTAssertGreaterThanOrEqual(chat.width, 640)
        try assertChatBarOrder(render)
        try save(render, "a2-ipad-portrait-1032")
    }

    func testPhoneChatBarEndsWithGitMoreAndInfo() async throws {
        let model = await fixture(), fleet = model.firstMateFleet
        model.selectedTab = .firstMate
        let target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        XCTAssertTrue(fleet.open(target))
        let store = try XCTUnwrap(fleet.store(for: target))
        let render = await IOSNativeRenderHarness().render(
            NavigationStack {
                FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: true, openInfo: { _, _ in })
                    .environment(\.firstMateInspectorContext, FirstMateInspectorContext(model: model, target: target,
                                                                                      featureTitle: "Receipt export", openGit: { _ in }))
            }.frame(height: 874), width: 402, dynamicType: .defaultSize, background: .dusk)
        XCTAssertTrue(render.drewHierarchy)
        try assertChatBarOrder(render)
        try save(render, "a2-iphone-chat-402")
    }

    /// Git, then ⋯, then the inspector/Info control on the far right.
    private func assertChatBarOrder(_ render: IOSNativeRenderHarness.HostedRender) throws {
        let git = try XCTUnwrap(render.element(identifier: "chat-git-control"), render.measurementDiagnostics).frame
        let more = try XCTUnwrap(render.element(identifier: "chat-more-control"), render.measurementDiagnostics).frame
        let info = try XCTUnwrap(render.element(identifier: "chat-info-control"), render.measurementDiagnostics).frame
        XCTAssertLessThan(git.maxX, more.minX + 1)
        XCTAssertLessThan(more.maxX, info.minX + 1)
        XCTAssertGreaterThanOrEqual(info.width, 43.9)
    }

    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-a2-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
    }
}
