import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate remote folder browser", .serialized)
@MainActor
struct FirstMateFolderBrowserTests {
    @Test("The companion supplies home and canonical paths, including an empty selectable folder")
    func canonicalHome() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let task = model.navigate(to: nil)
        await client.waitForRequest(1)
        #expect(await client.requests[0].path == nil)
        #expect(!model.canChooseCurrentFolder)
        await client.succeed(0, with: listing(path: "/home/demo", parent: "/home"))
        await task.value
        #expect(model.currentPath == "/home/demo")
        #expect(model.pathDraft == "/home/demo")
        #expect(model.entries.isEmpty)
        #expect(model.selectionPath() == "/home/demo")

        let alias = model.navigate(to: "/srv/projects/shortcut")
        await client.waitForRequest(2)
        await client.succeed(1, with: listing(path: "/srv/projects/app"))
        await alias.value
        #expect(model.selectionPath() == "/srv/projects/app")
    }

    @Test("A delayed old navigation cannot overwrite the latest folder")
    func delayedNavigation() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let old = model.navigate(to: "/srv/old")
        await client.waitForRequest(1)
        let current = model.navigate(to: "/srv/current")
        await client.waitForRequest(2)
        await client.succeed(1, with: listing(path: "/srv/current", names: ["current-child"]))
        await current.value
        await client.succeed(0, with: listing(path: "/srv/old", names: ["old-child"]))
        await old.value
        #expect(model.currentPath == "/srv/current")
        #expect(model.entries.map(\.name) == ["current-child"])
        #expect(model.selectionPath() == "/srv/current")
    }

    @Test("Hidden folder changes invalidate old pagination and use the new cursor")
    func hiddenPagination() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let initial = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        await client.succeed(0, with: listing(names: ["app"], next: "visible-next"))
        await initial.value
        let oldMore = model.loadMore()
        await client.waitForRequest(2)
        model.showHidden = true
        await client.waitForRequest(3)
        #expect(await client.requests[2].showHidden)
        #expect(await client.requests[2].cursor == nil)
        await client.succeed(2, with: listing(names: [".hidden", "app"], next: "hidden-next"))
        await settle(model)
        await client.succeed(1, with: listing(names: ["stale"], next: "visible-last"))
        await oldMore.value
        #expect(model.entries.map(\.name) == [".hidden", "app"])
        #expect(model.nextCursor == "hidden-next")
        let more = model.loadMore()
        await client.waitForRequest(4)
        #expect(await client.requests[3].showHidden)
        #expect(await client.requests[3].cursor == "hidden-next")
        await client.succeed(3, with: listing(names: [".another"]))
        await more.value
        #expect(model.entries.map(\.name) == [".hidden", "app", ".another"])
    }

    @Test("Overlapping pages are deduplicated without replacing a newly typed path")
    func pagination() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let initial = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        await client.succeed(0, with: listing(names: ["app", "app"], next: "next"))
        await initial.value
        let more = model.loadMore()
        await client.waitForRequest(2)
        model.pathDraft = "/srv/another folder "
        #expect(!model.canChooseCurrentFolder)
        await client.succeed(1, with: listing(names: ["app", "web", "web"]))
        await more.value
        #expect(model.entries.map(\.name) == ["app", "web"])
        #expect(model.pathDraft == "/srv/another folder ")
        #expect(model.selectionPath() == nil)
        model.goToDraft()
        await client.waitForRequest(3)
        #expect(await client.requests[2].path == "/srv/another folder ")
        await client.succeed(2, with: listing(path: "/srv/another folder "))
        await settle(model)
        #expect(model.selectionPath() == "/srv/another folder ")
    }

    @Test("A directory response preserves a different path typed before it arrives")
    func draftDuringNavigation() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let task = model.navigate(to: "/srv/projects/alias")
        await client.waitForRequest(1)
        model.pathDraft = "/srv/next-project"
        await client.succeed(0, with: listing(path: "/srv/projects/app"))
        await task.value
        #expect(model.currentPath == "/srv/projects/app")
        #expect(model.pathDraft == "/srv/next-project")
        #expect(model.hasUnsubmittedPath)
        #expect(model.selectionPath() == nil)
    }

    @Test("Missing and permission-denied paths retain the server explanation and disable selection", arguments: [403, 404])
    func inaccessiblePath(status: Int) async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let initial = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        await client.succeed(0, with: listing(names: ["app"]))
        await initial.value
        let inaccessible = model.navigate(to: "/srv/unavailable")
        await client.waitForRequest(2)
        let message = status == 403 ? "Permission denied for this folder." : "This folder no longer exists."
        await client.fail(1, error: APIError.server(status: status, message: message))
        await inaccessible.value
        #expect(model.error == message)
        #expect(model.isConnectionValid)
        #expect(!model.hasLoadedCurrentDirectory)
        #expect(model.currentPath == nil)
        #expect(model.parentPath == nil)
        #expect(model.selectionPath() == nil)
        let retry = model.retry()
        await client.waitForRequest(3)
        #expect(await client.requests[2].path == "/srv/unavailable")
        await client.succeed(2, with: listing(path: "/srv/unavailable"))
        await retry.value
        #expect(model.selectionPath() == "/srv/unavailable")
    }

    @Test("A failed next page blocks confirmation and can retry the same cursor")
    func failedPageRetry() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let initial = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        await client.succeed(0, with: listing(names: ["app"], next: "next"))
        await initial.value
        let more = model.loadMore()
        await client.waitForRequest(2)
        await client.fail(1, error: APIError.server(status: 403, message: "Folder access changed."))
        await more.value
        #expect(model.entries.map(\.name) == ["app"])
        #expect(model.selectionPath() == nil)
        let retry = model.retry()
        await client.waitForRequest(3)
        #expect(await client.requests[2].cursor == "next")
        await client.succeed(2, with: listing(names: ["web"]))
        await retry.value
        #expect(model.entries.map(\.name) == ["app", "web"])
        #expect(model.selectionPath() == "/srv/projects")
    }

    @Test("Cancelling the sheet fences a response even if transport ignores cancellation")
    func cancellation() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let task = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        model.cancel()
        await client.succeed(0, with: listing(names: ["late"]))
        await task.value
        #expect(!model.isLoading)
        #expect(model.entries.isEmpty)
        #expect(model.selectionPath() == nil)
    }

    @Test("Connection validity is rechecked on response and immediately before confirmation")
    func connectionInvalidation() async {
        let client = FolderBrowserClient()
        var current = true
        let model = FirstMateFolderBrowserModel(machineID: "machine-a", machineName: "Development Mac", client: client) { current }
        let initial = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        await client.succeed(0, with: listing())
        await initial.value
        #expect(model.canChooseCurrentFolder)
        current = false
        #expect(model.selectionPath() == nil)
        #expect(model.error?.contains("connection changed") == true)
        current = true
        #expect(model.selectionPath() == nil)

        var secondConnectionCurrent = true
        let second = FirstMateFolderBrowserModel(machineID: "machine-b", machineName: "Build Mac", client: client) { secondConnectionCurrent }
        let pending = second.navigate(to: nil)
        await client.waitForRequest(2)
        secondConnectionCurrent = false
        await client.succeed(1, with: listing())
        await pending.value
        #expect(second.entries.isEmpty)
        #expect(second.selectionPath() == nil)
        #expect(second.error?.contains("connection changed") == true)
    }

    @Test("Changing folders invalidates an in-flight page from the previous folder")
    func navigationDuringPagination() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let initial = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        await client.succeed(0, with: listing(names: ["app"], next: "next"))
        await initial.value
        let oldPage = model.loadMore()
        await client.waitForRequest(2)
        let nextFolder = model.navigate(to: "/srv/projects/app")
        await client.waitForRequest(3)
        await client.succeed(2, with: listing(path: "/srv/projects/app", names: ["Sources"]))
        await nextFolder.value
        await client.succeed(1, with: listing(names: ["obsolete"]))
        await oldPage.value
        #expect(model.entries.map(\.name) == ["Sources"])
        #expect(model.selectionPath() == "/srv/projects/app")
    }

    @Test("Malformed pagination cannot change the confirmed directory or loop a cursor")
    func invalidPagination() async {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let initial = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        await client.succeed(0, with: listing(names: ["app"], next: "next"))
        await initial.value
        let more = model.loadMore()
        await client.waitForRequest(2)
        await client.succeed(1, with: listing(path: "/srv/wrong", names: ["wrong"], next: "next"))
        await more.value
        #expect(model.entries.map(\.name) == ["app"])
        #expect(model.currentPath == "/srv/projects")
        #expect(model.error != nil)
        #expect(model.selectionPath() == nil)
    }

    @Test("Folder browser renders links and unavailable folders in both appearances", arguments: [ColorScheme.light, .dark])
    func render(scheme: ColorScheme) async throws {
        let client = FolderBrowserClient()
        let model = makeModel(client)
        let task = model.navigate(to: "/srv/projects")
        await client.waitForRequest(1)
        var response = listing(names: ["iOS App", "Web App"])
        response.entries.append(.init(name: "Shared components", path: "/srv/projects/shared", resolvedPath: "/srv/libraries/shared-components", isSymlink: true, canOpen: true))
        response.entries.append(.init(name: "Unavailable folder", path: "/srv/projects/unavailable", resolvedPath: nil, isSymlink: false, canOpen: false))
        await client.succeed(0, with: response)
        await task.value
        let render = try await HerdrRenderHarness.render("first-mate-folder-browser-\(scheme == .light ? "light" : "dark").png", size: CGSize(width: 700, height: 560)) {
            FirstMateFolderBrowserView(model: model) { _ in }
                .environment(\.colorScheme, scheme)
        }
        render.expectSubstantial(minimumBytes: 8_192)
    }

    private func makeModel(_ client: FolderBrowserClient) -> FirstMateFolderBrowserModel {
        .init(machineID: "machine-a", machineName: "Development Mac", client: client)
    }

    private func listing(path: String = "/srv/projects", parent: String? = "/srv", names: [String] = [], next: String? = nil) -> FirstMateDirectoryList {
        .init(ok: true, path: path, parentPath: parent, homePath: "/home/demo", entries: names.map {
            .init(name: $0, path: "\(path)/\($0)", resolvedPath: nil, isSymlink: false, canOpen: true)
        }, nextCursor: next)
    }

    private func settle(_ model: FirstMateFolderBrowserModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading || model.isLoadingMore {
            guard ContinuousClock.now < deadline else {
                Issue.record("Folder browser did not finish the resolved request")
                return
            }
            await Task.yield()
        }
    }
}

private actor FolderBrowserClient: FirstMateClient {
    struct Request: Sendable {
        let path: String?
        let showHidden: Bool
        let cursor: String?
    }
    private(set) var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<FirstMateDirectoryList, any Error>] = [:]
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func fetchDirectories(path: String?, showHidden: Bool, cursor: String?) async throws -> FirstMateDirectoryList {
        let index = requests.count
        requests.append(.init(path: path, showHidden: showHidden, cursor: cursor))
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = observers.filter { $0.count <= requests.count }
            observers.removeAll { $0.count <= requests.count }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitForRequest(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func succeed(_ index: Int, with response: FirstMateDirectoryList) {
        pending.removeValue(forKey: index)?.resume(returning: response)
    }

    func fail(_ index: Int, error: APIError) {
        pending.removeValue(forKey: index)?.resume(throwing: error)
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: []) }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
