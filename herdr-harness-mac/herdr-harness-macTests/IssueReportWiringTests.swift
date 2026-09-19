import AppKit
import Foundation
import Testing
@testable import herdr_harness_mac

/// The glue around the composer: app-model gating, the Settings ▸ Feedback
/// hand-off to the main window, the shell's blocking-modal flag and the ⌘V
/// interception rule. Everything here runs without a window or a server.
@Suite("Issue report wiring", .serialized)
@MainActor
struct IssueReportWiringTests {
    @Test("Demo mode and missing connections are refused before any request is built")
    func appModelGating() async throws {
        let suite = "IssueReportWiringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: defaults,
            configuredMachines: []
        )
        #expect(model.isDemoMode)

        await expectServerError(status: 503, message: "Reports are unavailable in demo mode.") {
            _ = try await model.submitIssueReport(Self.request, machineID: "m1")
        }
        await expectServerError(status: 503, message: "Reports are unavailable in demo mode.") {
            _ = try await model.issueReportCapabilities(machineID: "m1")
        }

        model.isDemoMode = false
        await expectNoActiveConnection(machineID: "m1") {
            _ = try await model.submitIssueReport(Self.request, machineID: "m1")
        }
        await expectNoActiveConnection(machineID: "m1") {
            _ = try await model.issueReportCapabilities(machineID: "m1")
        }
    }

    @Test("A live paired machine is discovered through the app model and remembered after filing")
    func discoveryThroughAppModel() async throws {
        let suite = "IssueReportWiringTests.discovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
        let alpha = HerdrMachine(id: "alpha", name: "Alpha", urlString: "https://alpha.example.invalid")
        let beta = HerdrMachine(id: "beta", name: "Beta", urlString: "https://beta.example.invalid")
        model.machines = [alpha, beta]
        model.clientFactory = { configuration in
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [WiringReportStubURLProtocol.self]
            return HerdrAPIClient(configuration: configuration, session: URLSession(configuration: session))
        }
        model.prepareRuntime(for: alpha, generation: model.connectionGeneration)
        model.machineStates[alpha.id] = .live
        model.machineStates[beta.id] = .disconnected

        let connectedIDs = IssueReportComposer.connectedMachineIDs(
            machines: model.machines,
            isDemoMode: model.isDemoMode,
            connectionState: { model.connectionState(forMachine: $0) }
        )
        #expect(connectedIDs == ["alpha"])

        let composer = IssueReportComposer(userDefaults: defaults)
        await composer.discover(machines: model.machines, connectedIDs: connectedIDs) { machineID in
            try await model.issueReportCapabilities(machineID: machineID)
        }

        #expect(composer.machineID == "alpha")
        #expect(IssueReportMachineSelection.isAvailable(composer.machineChecks["alpha"]))
        #expect(composer.machineChecks["beta"] == .disconnected)
        #expect(composer.selectedMachineAvailable)
        #expect(composer.capabilities?.repository == "owner/repo")

        composer.title = "Crash on launch"
        composer.body = "It crashed."
        #expect(composer.canSubmit)
        await composer.submit(environment: ["client": "herdr-companion-mac"]) { request, machineID in
            try await model.submitIssueReport(request, machineID: machineID)
        }
        #expect(composer.submittedRecord?.issueNumber == 42)
        #expect(defaults.string(forKey: IssueReportComposer.lastSuccessfulMachineIDKey) == "alpha")
    }

    @Test("The report sheet blocks agent control only while it is presented")
    func shellBlockingModal() throws {
        let suite = "IssueReportWiringTests.shell.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let shell = HerdrShellState(userDefaults: defaults)

        #expect(shell.agentControlBlockingModal == nil)
        shell.isIssueReportPresented = true
        #expect(shell.agentControlBlockingModal == "issue-report")
        shell.isIssueReportPresented = false
        #expect(shell.agentControlBlockingModal == nil)
    }

    @Test("A Settings request is parked until a main window drains it, exactly once")
    func pendingIssueReportDrainsOnce() {
        _ = HerdrMacAppDelegate.takePendingIssueReport()
        #expect(!HerdrMacAppDelegate.takePendingIssueReport())

        let posted = NotificationCounter(name: .herdrPresentIssueReport)
        defer { posted.stop() }
        HerdrMacAppDelegate.requestIssueReport()

        // The open window hears the notification; a window still being
        // recreated by `openWindow` finds the flag in its first `.task`.
        #expect(posted.count == 1)
        #expect(HerdrMacAppDelegate.takePendingIssueReport())
        #expect(!HerdrMacAppDelegate.takePendingIssueReport())
    }

    @Test("⌘V is intercepted only for image-only clipboards outside the description")
    func pasteInterception() {
        let imageOnly: [NSPasteboard.PasteboardType] = [.tiff, .png]
        let imageAndText: [NSPasteboard.PasteboardType] = [.tiff, .string]
        let finderCopy: [NSPasteboard.PasteboardType] = [.fileURL, .string]
        let richText: [NSPasteboard.PasteboardType] = [.rtf, NSPasteboard.PasteboardType("public.utf16-external-plain-text")]

        #expect(IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "v", isBodyFocused: false, pasteboardTypes: imageOnly))
        #expect(IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "V", isBodyFocused: false, pasteboardTypes: imageOnly))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "v", isBodyFocused: true, pasteboardTypes: imageOnly))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "v", isBodyFocused: false, pasteboardTypes: imageAndText))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "v", isBodyFocused: false, pasteboardTypes: finderCopy))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "v", isBodyFocused: false, pasteboardTypes: richText))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "v", isBodyFocused: false, pasteboardTypes: []))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: [.command, .shift], key: "v", isBodyFocused: false, pasteboardTypes: imageOnly))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: [.command, .option], key: "v", isBodyFocused: false, pasteboardTypes: imageOnly))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: [], key: "v", isBodyFocused: false, pasteboardTypes: imageOnly))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: "c", isBodyFocused: false, pasteboardTypes: imageOnly))
        #expect(!IssueReportPasteInterceptor.shouldIntercept(modifiers: .command, key: nil, isBodyFocused: false, pasteboardTypes: imageOnly))

        #expect(IssueReportPasteInterceptor.holdsImageWithoutText([NSPasteboard.PasteboardType("public.heic")]))
        #expect(!IssueReportPasteInterceptor.holdsImageWithoutText([.fileURL]))
        #expect(!IssueReportPasteInterceptor.holdsImageWithoutText([.png, .html]))
    }

    @Test("A live pasteboard holding only an image is attached; one with text is left alone")
    func pasteboardImport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "herdr-issue-report-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Self.pngBytes, forType: .png)

        #expect(composer.importPasteboardImage(pasteboard))
        #expect(composer.attachments.map(\.filename) == ["pasted-image-1.png"])
        #expect(try Data(contentsOf: composer.attachments[0].url) == Self.pngBytes)

        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        #expect(!composer.importPasteboardImage(pasteboard))
        #expect(composer.attachments.count == 1)
    }

    // MARK: - Helpers

    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    private static let request = IssueReportRequest(
        kind: .bug,
        title: "Crash on launch",
        body: "It crashed.",
        autofix: true,
        environment: ["client": "herdr-companion-mac"],
        attachments: [],
        clientReportId: "wiring-report-01"
    )

    private func expectServerError(status: Int, message: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected a \(status) server error")
        } catch let error as APIError {
            guard case let .server(gotStatus, gotMessage) = error else {
                Issue.record("Expected a server error, got \(error)")
                return
            }
            #expect(gotStatus == status)
            #expect(gotMessage == message)
        } catch {
            Issue.record("Expected an APIError, got \(error)")
        }
    }

    private func expectNoActiveConnection(machineID: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected noActiveConnection")
        } catch let error as APIError {
            guard case let .noActiveConnection(gotMachineID) = error else {
                Issue.record("Expected noActiveConnection, got \(error)")
                return
            }
            #expect(gotMachineID == machineID)
        } catch {
            Issue.record("Expected an APIError, got \(error)")
        }
    }
}

/// Counts synchronous deliveries of one notification name.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var observer: NSObjectProtocol?

    init(name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            lock.withLock { value += 1 }
        }
    }

    var count: Int { lock.withLock { value } }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Serves the capability list, the report-capabilities endpoint and the report
/// POST from canned replies for the app-model wiring test. The suite is
/// serialized, so one shared set of replies is enough.
private final class WiringReportStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, reply) = reply(for: request, url: url)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func reply(for request: URLRequest, url: URL) -> (Int, String) {
        drainBody(of: request)
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/api/v1"):
            return (200, #"{"ok":true,"capabilities":["issue-reports-v1"]}"#)
        case ("GET", "/api/v1/issue-reports/capabilities"):
            return (200, """
            {"ok":true,"available":true,"repository":"owner/repo","reason":null,"maxAttachments":6,
             "maxAttachmentBytes":20971520,"maxTotalAttachmentBytes":41943040,"publicRepository":true}
            """)
        case ("POST", "/api/v1/issue-reports"):
            return (201, """
            {"ok":true,"report":{"id":"isr_0123456789ab","kind":"bug","title":"Crash on launch",
             "autofix":true,"issueNumber":42,"issueUrl":"https://github.com/owner/repo/issues/42",
             "repository":"owner/repo","attachments":[],"createdAt":"2026-09-18T12:00:00Z"}}
            """)
        default:
            return (404, #"{"ok":false,"error":{"code":"not_found","message":"Not found"}}"#)
        }
    }

    /// URLSession hands protocols a body stream, not `httpBody`; drain it so
    /// nothing in the request machinery waits on an unread body.
    private func drainBody(of request: URLRequest) {
        guard let stream = request.httpBodyStream else { return }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            guard stream.read(&buffer, maxLength: buffer.count) > 0 else { break }
        }
    }
}
