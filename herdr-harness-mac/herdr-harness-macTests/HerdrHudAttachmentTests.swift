import AppKit
import Foundation
import UniformTypeIdentifiers
import Testing
@testable import herdr_harness_mac

/// Real encoded images for drop tests. The previous suite used a four-byte PNG
/// header, which no image decoder or thumbnail loader can read; these fixtures
/// exercise the whole production path, including thumbnail generation.
enum HerdrDropImageFixtures {
    static func makePNG() -> Data {
        encodedImage(type: .png, properties: [:])
    }

    static func makeJPEG() -> Data {
        encodedImage(type: .jpeg, properties: [.compressionFactor: 0.85])
    }

    static func makeTIFF() -> Data {
        encodedImage(type: .tiff, properties: [:])
    }

    private static func encodedImage(
        type: NSBitmapImageRep.FileType,
        properties: [NSBitmapImageRep.PropertyKey: Any]
    ) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        precondition(rep != nil, "Could not allocate an image fixture")
        return rep?.representation(using: type, properties: properties) ?? Data()
    }
}

/// A promise receiver that fulfills or fails without a live drag, so the whole
/// promised-file path is deterministic in tests.
@MainActor
final class SyntheticPromiseReceiver: HerdrPromisedFileReceiver {
    enum Outcome {
        case file(name: String, data: Data)
        case failure(any Error)
        case noFile
    }

    let outcome: Outcome
    private(set) var stagingDirectories: [URL] = []
    private(set) var deliveredFiles: [URL] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func loadPromisedFiles(
        atDestination directory: URL,
        operationQueue: OperationQueue,
        completion: @escaping (URL?, (any Error)?) -> Void
    ) {
        stagingDirectories.append(directory)
        switch outcome {
        case let .file(name, data):
            do {
                let url = directory.appendingPathComponent(name)
                try data.write(to: url)
                deliveredFiles.append(url)
                completion(url, nil)
            } catch {
                completion(nil, error)
            }
        case let .failure(error):
            completion(nil, error)
        case .noFile:
            completion(nil, nil)
        }
    }
}

struct SyntheticPromiseError: LocalizedError {
    var errorDescription: String? { "The promised file could not be written." }
}

@Suite("Herdr HUD attachments")
@MainActor
struct HerdrHudAttachmentTests {
    // MARK: - SwiftUI provider route

    @Test("Dropped image data completed on a background queue becomes a durable sendable attachment")
    func imageDataDrop() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(10)) {
                completion(bytes, nil)
            }
            return nil
        }
        let session = makeSession()
        #expect(session.acceptAttachmentDrop([provider]))
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.isImage)
        #expect(try Data(contentsOf: attachment.url) == bytes)
        session.removeAttachment(attachment.id)
        #expect(!FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test("A file provider imports the original file under its own name")
    func fileURLProviderDrop() async throws {
        let source = temporaryURL(named: "notes.txt")
        let bytes = Data("Keep this attachment".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = makeSession()
        #expect(session.acceptAttachmentDrop([NSItemProvider(object: source as NSURL)]))
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.filename == source.lastPathComponent)
        #expect(!attachment.isImage)
        #expect(try Data(contentsOf: attachment.url) == bytes)
    }

    @Test("An unloadable image representation falls through to the next registered type")
    func imageCandidatesFallThrough() async throws {
        let bytes = HerdrDropImageFixtures.makeJPEG()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }

        let session = makeSession()
        #expect(session.acceptAttachmentDrop([provider]))
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.isImage)
        #expect(try Data(contentsOf: attachment.url) == bytes)
    }

    @Test("A file-backed provider representation is copied before AppKit deletes it")
    func fileBackedProviderDrop() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let session = makeSession()
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-provider.png")
            try? bytes.write(to: source)
            completion(source, false, nil)
            return nil
        }

        #expect(session.acceptAttachmentDrop([provider]))
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.isImage)
        #expect(try Data(contentsOf: attachment.url) == bytes)
    }

    @Test("A provider that completes its load twice imports exactly one attachment")
    func duplicateProviderCompletion() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            completion(bytes, nil)
            return nil
        }
        let session = makeSession()
        #expect(session.acceptAttachmentDrop([provider]))
        try await waitForAttachments(session, count: 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.pendingAttachments.count == 1)
        #expect(session.validationError == nil)
    }

    @Test("A provider with no readable representation reports a recoverable error")
    func unreadableProviderReportsError() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let session = makeSession()
        session.draft = "Keep this draft"
        #expect(session.acceptAttachmentDrop([provider]))
        try await waitForAttachmentError(session)
        #expect(session.pendingAttachments.isEmpty)
        #expect(session.draft == "Keep this draft")
    }

    @Test("Unrelated providers never accept a drop")
    func unrelatedProviderRejected() {
        let session = makeSession()
        #expect(!session.acceptAttachmentDrop([NSItemProvider(object: "text" as NSString)]))
        #expect(session.pendingAttachments.isEmpty)
    }

    // MARK: - AppKit pasteboard route

    @Test("PNG, TIFF, and JPEG pasteboards each import one usable image")
    func pasteboardImageFormats() async throws {
        let payloads: [(type: NSPasteboard.PasteboardType, bytes: Data)] = [
            (.png, HerdrDropImageFixtures.makePNG()),
            (.tiff, HerdrDropImageFixtures.makeTIFF()),
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), HerdrDropImageFixtures.makeJPEG()),
        ]
        for payload in payloads {
            let session = makeSession()
            let pasteboard = makePasteboard { $0.setData(payload.bytes, forType: payload.type) }
            #expect(session.acceptPasteboardDrop(pasteboard))
            try await waitForAttachments(session, count: 1)
            let attachment = try #require(session.pendingAttachments.first)
            #expect(attachment.isImage)
            #expect(try Data(contentsOf: attachment.url) == payload.bytes)
            session.removeAttachment(attachment.id)
        }
    }

    @Test("A file URL pasteboard keeps the original file and name")
    func pasteboardFileURL() async throws {
        let source = temporaryURL(named: "photo.png")
        let bytes = HerdrDropImageFixtures.makePNG()
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = makeSession()
        let pasteboard = makePasteboard { $0.writeObjects([source as NSURL]) }
        #expect(session.acceptPasteboardDrop(pasteboard))
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.filename == source.lastPathComponent)
        #expect(try Data(contentsOf: attachment.url) == bytes)
    }

    @Test("A browser image drag carrying its web URL still attaches the pixels")
    func browserImagePasteboard() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let session = makeSession()
        let pasteboard = makePasteboard {
            $0.setData(Data("https://example.invalid/photo.png".utf8), forType: NSPasteboard.PasteboardType("public.url"))
            $0.setData(bytes, forType: .png)
        }
        #expect(session.acceptPasteboardDrop(pasteboard))
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.isImage)
        #expect(try Data(contentsOf: attachment.url) == bytes)
        #expect(session.validationError == nil)
    }

    @Test("A web-URL-only drag is rejected instead of trying to read a URL as a file")
    func webURLOnlyPasteboardRejected() {
        let session = makeSession()
        let pasteboard = makePasteboard {
            $0.setData(Data("https://example.invalid/page".utf8), forType: NSPasteboard.PasteboardType("public.url"))
        }
        #expect(!session.acceptPasteboardDrop(pasteboard))
        #expect(session.pendingAttachments.isEmpty)
    }

    @Test("Unsupported pasteboards never become HUD attachments")
    func unsupportedPasteboardRejected() {
        let session = makeSession()
        let pasteboard = makePasteboard { $0.setString("hello", forType: .string) }
        #expect(!session.acceptPasteboardDrop(pasteboard))
        #expect(session.pendingAttachments.isEmpty)
        #expect(session.validationError == nil)
    }

    @Test("Oversized and empty image data stay recoverable and keep the draft")
    func pasteboardImageValidation() async throws {
        let oversized = makeSession()
        let oversizedPasteboard = makePasteboard {
            $0.setData(Data(repeating: 0xAB, count: Int(AttachmentPolicy.maximumFileBytes) + 1), forType: .png)
        }
        oversized.draft = "Keep this draft"
        #expect(oversized.acceptPasteboardDrop(oversizedPasteboard))
        try await waitForAttachmentError(oversized)
        #expect(oversized.pendingAttachments.isEmpty)
        #expect(oversized.draft == "Keep this draft")

        let empty = makeSession()
        let emptyPasteboard = makePasteboard { $0.setData(Data(), forType: .png) }
        #expect(empty.acceptPasteboardDrop(emptyPasteboard))
        try await waitForAttachmentError(empty)
        #expect(empty.pendingAttachments.isEmpty)
    }

    // MARK: - Promised files

    @Test("A fulfilled screenshot promise becomes a durable attachment and cleans up its staging copy")
    func fulfilledPromise() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let receiver = SyntheticPromiseReceiver(.file(name: "Screenshot.png", data: bytes))
        let session = makeSession()
        session.acceptPromisedFiles([receiver])
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.filename == "Screenshot.png")
        #expect(attachment.isImage)
        #expect(try Data(contentsOf: attachment.url) == bytes)

        let delivered = try #require(receiver.deliveredFiles.first)
        #expect(!FileManager.default.fileExists(atPath: delivered.path))
        let staging = try #require(receiver.stagingDirectories.first)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("A failed promise reports a recoverable error and leaves drafts intact")
    func failedPromise() async throws {
        let receiver = SyntheticPromiseReceiver(.failure(SyntheticPromiseError()))
        let session = makeSession()
        session.draft = "Keep this draft"
        session.acceptPromisedFiles([receiver])
        try await waitForAttachmentError(session)
        #expect(session.pendingAttachments.isEmpty)
        #expect(session.draft == "Keep this draft")
        #expect(session.validationError?.contains("Couldn't attach") == true)
    }

    @Test("A promise that delivers no file reports a recoverable error")
    func emptyPromise() async throws {
        let session = makeSession()
        session.acceptPromisedFiles([SyntheticPromiseReceiver(.noFile)])
        try await waitForAttachmentError(session)
        #expect(session.pendingAttachments.isEmpty)
    }

    // MARK: - Repeatability, durability, and explicit submission

    @Test("Three consecutive drop/remove cycles each import exactly one attachment")
    func repeatedDropRemoveCycles() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let session = makeSession()
        for cycle in 0..<3 {
            let pasteboard = makePasteboard { $0.setData(bytes, forType: .png) }
            #expect(session.acceptPasteboardDrop(pasteboard), "cycle \(cycle) was not accepted")
            try await waitForAttachments(session, count: 1)
            let attachment = try #require(session.pendingAttachments.first)
            #expect(try Data(contentsOf: attachment.url) == bytes)
            session.removeAttachment(attachment.id)
            try await waitForRemoval(session)
            #expect(session.pendingAttachments.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: attachment.url.path))
        }
        #expect(session.validationError == nil)
    }

    @Test("Attachment-only sends retain inline files after the source is removed and history restored")
    func attachmentOnlySubmissionRetainsInlineFile() async throws {
        let source = temporaryURL(named: "notes.txt")
        let bytes = Data("Keep this attachment".utf8)
        try bytes.write(to: source)
        let session = makeSession()
        session.addAttachments([source])
        let attachment = try #require(session.pendingAttachments.first)
        try FileManager.default.removeItem(at: source)
        await session.submit(model: makeDemoModel())
        let exchange = try #require(session.exchanges.last)
        #expect(exchange.status == .completed)
        #expect(exchange.localAttachments == [attachment])
        #expect(exchange.attachments.isEmpty)
        #expect(try Data(contentsOf: attachment.url) == bytes)

        let snapshot = HerdrHudPersistenceSnapshot(thread: session.thread, exchanges: session.exchanges)
        let restored = try JSONDecoder().decode(HerdrHudPersistenceSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.restoredValues().exchanges.last?.localAttachments == [attachment])
        await session.clear(model: makeDemoModel())
        #expect(!FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test("A dropped image stays readable after the source is removed and is submitted explicitly")
    func droppedImageExplicitSubmission() async throws {
        let source = temporaryURL(named: "launch-shot.png")
        let bytes = HerdrDropImageFixtures.makePNG()
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = makeSession()
        let pasteboard = makePasteboard { $0.writeObjects([source as NSURL]) }
        #expect(session.acceptPasteboardDrop(pasteboard))
        try await waitForAttachments(session, count: 1)
        let attachment = try #require(session.pendingAttachments.first)

        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: attachment.url) == bytes)

        session.draft = "Read this screenshot"
        await session.submit(model: makeDemoModel())
        let exchange = try #require(session.exchanges.last)
        #expect(exchange.localAttachments == [attachment])
        #expect(try Data(contentsOf: attachment.url) == bytes)
        #expect(session.lastHeadlessRunForTesting != nil)
    }

    // MARK: - Existing validation policy

    @Test("Allowed files are accepted and image classification is retained")
    func allowedFilesAreAcceptedAndClassified() throws {
        let textURL = temporaryURL(named: "notes.txt")
        let pdfURL = temporaryURL(named: "report.pdf")
        let imageURL = temporaryURL(named: "photo.png")
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: pdfURL)
            try? FileManager.default.removeItem(at: imageURL)
        }
        try Data("notes".utf8).write(to: textURL)
        try Data("%PDF-1.4".utf8).write(to: pdfURL)
        try HerdrDropImageFixtures.makePNG().write(to: imageURL)

        let session = makeSession()
        session.addAttachments([textURL, pdfURL, imageURL])

        #expect(session.validationError == nil)
        #expect(session.pendingAttachments.map(\.filename) == [
            textURL.lastPathComponent, pdfURL.lastPathComponent, imageURL.lastPathComponent,
        ])
        #expect(session.pendingAttachments.map(\.isImage) == [false, false, true])
    }

    @Test("Unsupported files are rejected")
    func unsupportedFilesAreRejected() throws {
        let url = temporaryURL(named: "unsupported.exe")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x01]).write(to: url)

        let session = makeSession()
        session.addAttachments([url])

        #expect(session.pendingAttachments.isEmpty)
        #expect(session.validationError != nil)
    }

    @Test("The four-file cap remains enforced for repeated drops")
    func enforcesFourFileCap() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let session = makeSession()
        for cycle in 0..<4 {
            let pasteboard = makePasteboard { $0.setData(bytes, forType: .png) }
            #expect(session.acceptPasteboardDrop(pasteboard), "cycle \(cycle) was not accepted")
            try await waitForAttachments(session, count: cycle + 1)
        }
        #expect(session.pendingAttachments.count == 4)

        let extra = makePasteboard { $0.setData(bytes, forType: .png) }
        #expect(session.acceptPasteboardDrop(extra))
        try await waitForAttachmentError(session)
        #expect(session.pendingAttachments.count == 4)
    }

    @Test("The aggregate cap remains enforced")
    func enforcesAggregateCap() throws {
        let firstURL = temporaryURL(named: "first.txt")
        let secondURL = temporaryURL(named: "second.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: firstURL)
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: secondURL)

        let session = makeSession()
        session.addAttachments([firstURL, secondURL])

        #expect(session.pendingAttachments.map(\.filename) == [firstURL.lastPathComponent])
        #expect(session.validationError != nil)
    }

    @Test("Only image attachments select a vision model")
    func onlyImageAttachmentsSelectVisionModel() async throws {
        let textURL = temporaryURL(named: "notes.txt")
        let imageURL = temporaryURL(named: "photo.png")
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: imageURL)
        }
        try Data("notes".utf8).write(to: textURL)
        try HerdrDropImageFixtures.makePNG().write(to: imageURL)

        let textSession = makeSession()
        textSession.addAttachments([textURL])
        textSession.draft = "Read these notes"
        await textSession.submit(model: makeDemoModel())
        #expect(textSession.lastHeadlessRunForTesting?.model == nil)

        let imageSession = makeSession()
        imageSession.addAttachments([textURL, imageURL])
        imageSession.draft = "Read these files"
        await imageSession.submit(model: makeDemoModel())
        #expect(imageSession.lastHeadlessRunForTesting?.model == HerdrHudModelRouting.visionModel)
    }

    // MARK: - Helpers

    private func makePasteboard(_ configure: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HerdrHudAttachmentTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        configure(pasteboard)
        return pasteboard
    }

    private func waitForAttachments(_ session: HerdrHudSession, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.pendingAttachments.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.pendingAttachments.count == count)
    }

    private func waitForAttachmentError(_ session: HerdrHudSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.validationError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.validationError != nil)
    }

    private func waitForRemoval(_ session: HerdrHudSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !session.pendingAttachments.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func makeDemoModel() -> HerdrAppModel {
        HerdrAppModel(
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: makeDefaults(prefix: "model")
        )
    }

    private func makeSession() -> HerdrHudSession {
        HerdrHudSession(
            userDefaults: makeDefaults(prefix: "session"),
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
    }

    private func makeDefaults(prefix: String) -> UserDefaults {
        let suiteName = "HerdrHudAttachmentTests.\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
