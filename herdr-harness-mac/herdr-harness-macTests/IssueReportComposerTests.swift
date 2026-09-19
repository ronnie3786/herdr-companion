import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import herdr_harness_mac

@Suite("Issue report composer", .serialized)
@MainActor
struct IssueReportComposerTests {
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    @Test("Environment details contain exactly the allowed keys")
    func environmentDetailsKeys() {
        let details = IssueReportComposer.environmentDetails(
            appVersion: "0.20.0",
            build: "412",
            macOSVersion: "Version 26.0 (Build 25A123)",
            machineRole: "review",
            serverCapabilities: ["pane-retirement-v1", " issue-reports-v1 ", ""]
        )

        #expect(Set(details.keys) == ["app_version", "app_build", "macos_version", "machine_role", "server_capabilities", "client"])
        #expect(details["app_version"] == "0.20.0")
        #expect(details["app_build"] == "412")
        #expect(details["macos_version"] == "Version 26.0 (Build 25A123)")
        #expect(details["machine_role"] == "review")
        #expect(details["server_capabilities"] == "pane-retirement-v1,issue-reports-v1")
        #expect(details["client"] == "herdr-companion-mac")

        let joined = details.values.joined(separator: "\n")
        #expect(!joined.contains("example.invalid"))
        #expect(!joined.contains("https://"))
    }

    @Test("Environment details omit the role when absent and strip control characters")
    func environmentDetailsOmitsRole() {
        let details = IssueReportComposer.environmentDetails(
            appVersion: "0.20.0\u{0007}",
            build: "412",
            macOSVersion: "26.0",
            machineRole: "  ",
            serverCapabilities: []
        )

        #expect(Set(details.keys) == ["app_version", "app_build", "macos_version", "server_capabilities", "client"])
        #expect(details["app_version"] == "0.20.0")
        #expect(details["server_capabilities"] == "")

        let long = IssueReportComposer.environmentDetails(
            appVersion: String(repeating: "v", count: 600),
            build: "1",
            macOSVersion: "26.0",
            machineRole: nil,
            serverCapabilities: []
        )
        #expect(long["app_version"]?.count == IssueReportComposer.maxEnvironmentValueLength)
    }

    @Test("canSubmit requires a title, a description, an available machine and no submission in flight")
    func canSubmitMatrix() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        #expect(!composer.canSubmit)

        composer.machineID = "machine-1"
        composer.title = "   "
        composer.body = "Something broke"
        #expect(!composer.canSubmit)

        composer.title = "Crash on launch"
        composer.body = " \n\t"
        #expect(!composer.canSubmit)

        // A complete draft still waits for capabilities that answered available.
        composer.body = "Something broke"
        #expect(!composer.canSubmit)

        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        #expect(composer.canSubmit)

        composer.machineID = ""
        #expect(!composer.canSubmit)

        composer.machineID = "machine-1"
        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        composer.phase = .submitting
        #expect(!composer.canSubmit)

        composer.phase = .failed("network")
        #expect(composer.canSubmit)

        composer.phase = .submitted(Self.record)
        #expect(!composer.canSubmit)

        composer.phase = .editing
        composer.title = String(repeating: "x", count: IssueReportComposer.maxTitleCharacters + 1)
        #expect(!composer.canSubmit)

        composer.title = "Crash on launch"
        composer.body = String(repeating: "y", count: IssueReportComposer.maxBodyCharacters + 1)
        #expect(!composer.canSubmit)

        // An unavailable companion can never submit, even with a valid draft.
        composer.body = "Something broke"
        composer.capabilities = IssueReportCapabilities(available: false, reason: "No repository is configured.")
        #expect(!composer.canSubmit)
    }

    @Test("Attachments are validated by extension, size, count and total")
    func attachmentValidation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        let notes = try write("notes.txt", Data("hello".utf8), in: directory)
        let archive = try write("archive.zip", Data([0x50, 0x4B]), in: directory)
        let empty = try write("empty.md", Data(), in: directory)

        composer.addAttachments([archive])
        #expect(composer.attachments.isEmpty)
        #expect(composer.attachmentError == "archive.zip isn't a supported file type.")

        composer.addAttachments([empty])
        #expect(composer.attachments.isEmpty)
        #expect(composer.attachmentError == "empty.md is empty and cannot be attached.")

        composer.addAttachments([notes])
        #expect(composer.attachments.map(\.filename) == ["notes.txt"])
        #expect(composer.attachments[0].byteCount == 5)
        #expect(composer.attachments[0].ownership == .userSelected)
        #expect(!composer.attachments[0].isImage)
        #expect(composer.attachmentError == nil)

        composer.addAttachments([notes])
        #expect(composer.attachments.count == 1)
        #expect(composer.attachmentError == "notes.txt is already attached.")

        // Server-advertised limits lower the client ceilings.
        composer.capabilities = IssueReportCapabilities(
            available: true,
            repository: "owner/repo",
            maxAttachments: 2,
            maxAttachmentBytes: 8,
            maxTotalAttachmentBytes: 12
        )
        let big = try write("big.log", Data(repeating: 0x41, count: 9), in: directory)
        composer.addAttachments([big])
        #expect(composer.attachments.count == 1)
        #expect(composer.attachmentError == "big.log is larger than the file limit of 8 bytes.")

        let small = try write("small.log", Data(repeating: 0x41, count: 5), in: directory)
        composer.addAttachments([small])
        #expect(composer.attachments.map(\.filename) == ["notes.txt", "small.log"])
        #expect(composer.attachmentByteTotal == 10)

        let third = try write("third.log", Data([0x41]), in: directory)
        composer.addAttachments([third])
        #expect(composer.attachments.count == 2)
        #expect(composer.attachmentError == "Attach up to 2 files per report.")

        composer.capabilities = IssueReportCapabilities(
            available: true,
            repository: "owner/repo",
            maxAttachments: 6,
            maxAttachmentBytes: 8,
            maxTotalAttachmentBytes: 12
        )
        let overflow = try write("overflow.log", Data(repeating: 0x41, count: 3), in: directory)
        composer.addAttachments([overflow])
        #expect(composer.attachments.count == 2)
        #expect(composer.attachmentError == "Attachments can total up to 12 bytes per report.")

        // Server limits can never raise the client ceilings.
        composer.capabilities = IssueReportCapabilities(available: true, maxAttachments: 50, maxAttachmentBytes: .max, maxTotalAttachmentBytes: .max)
        #expect(composer.effectiveMaxAttachments == IssueReportComposer.maxAttachments)
        #expect(composer.effectiveMaxAttachmentBytes == AttachmentPolicy.maximumFileBytes)
        #expect(composer.effectiveMaxTotalAttachmentBytes == AttachmentPolicy.maximumAggregateBytes)
    }

    @Test("The hard cap of six attachments applies without server limits")
    func hardAttachmentCap() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        let urls = try (1...7).map { try write("file-\($0).txt", Data("x".utf8), in: directory) }
        composer.addAttachments(urls)

        #expect(composer.attachments.count == 6)
        #expect(composer.attachmentError == "Attach up to 6 files per report.")
    }

    @Test("makeRequest keeps the body verbatim and encodes attachments with MIME types")
    func makeRequestVerbatim() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        composer.machineID = "machine-1"
        composer.kind = .feature
        composer.autofix = false
        composer.title = "  Add a\nquiet mode  "
        composer.body = "  leading spaces kept\n\n## Markdown 🚀\n| a | b |\n\ttabs too\n\n\n"

        let png = try write("shot.png", Self.pngBytes, in: directory)
        let markdown = try write("notes.md", Data("# notes".utf8), in: directory)
        let text = try write("log.txt", Data("line".utf8), in: directory)
        composer.addAttachments([png, markdown, text])
        #expect(composer.attachments.count == 3)
        #expect(composer.attachments[0].isImage)

        let request = try composer.makeRequest(environment: ["client": "herdr-companion-mac", "app_version": "0.20.0"])

        #expect(request.kind == .feature)
        #expect(!request.autofix)
        #expect(request.title == "Add a quiet mode")
        #expect(request.body == "  leading spaces kept\n\n## Markdown 🚀\n| a | b |\n\ttabs too")
        #expect(request.environment == ["client": "herdr-companion-mac", "app_version": "0.20.0"])
        #expect(request.clientReportId == composer.clientReportId)
        #expect(request.attachments.map(\.filename) == ["shot.png", "notes.md", "log.txt"])
        #expect(request.attachments.map(\.contentType) == ["image/png", "text/markdown", "text/plain"])
        #expect(Data(base64Encoded: request.attachments[0].dataBase64) == Self.pngBytes)
        #expect(Data(base64Encoded: request.attachments[1].dataBase64) == Data("# notes".utf8))

        #expect(IssueReportComposer.contentType(forFilename: "archive.unknownext") == "application/octet-stream")
        #expect(IssueReportComposer.contentType(forFilename: "README") == "application/octet-stream")
        #expect(IssueReportComposer.contentType(forFilename: "doc.pdf") == "application/pdf")
    }

    @Test("makeRequest rejects blank drafts before reading any file")
    func makeRequestValidation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        #expect(throws: IssueReportComposerError.noMachineSelected) {
            try composer.makeRequest(environment: [:])
        }
        composer.machineID = "machine-1"
        #expect(throws: IssueReportComposerError.missingTitle) {
            try composer.makeRequest(environment: [:])
        }
        composer.title = "Title"
        #expect(throws: IssueReportComposerError.missingDescription) {
            try composer.makeRequest(environment: [:])
        }
        composer.body = "\n\n"
        #expect(throws: IssueReportComposerError.missingDescription) {
            try composer.makeRequest(environment: [:])
        }
        composer.body = "Body"
        composer.title = String(repeating: "t", count: 201)
        #expect(throws: IssueReportComposerError.titleTooLong(maximum: 200)) {
            try composer.makeRequest(environment: [:])
        }

        // An attachment deleted after it was queued fails loudly, not silently.
        composer.title = "Title"
        let vanishing = try write("vanishing.txt", Data("x".utf8), in: directory)
        composer.addAttachments([vanishing])
        try FileManager.default.removeItem(at: vanishing)
        #expect(throws: IssueReportComposerError.attachmentUnreadable(filename: "vanishing.txt")) {
            try composer.makeRequest(environment: [:])
        }
    }

    @Test("makeRequest bounds the environment block")
    func makeRequestBoundsEnvironment() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))
        composer.machineID = "machine-1"
        composer.title = "Title"
        composer.body = "Body"

        var environment: [String: String] = [:]
        for index in 0..<50 {
            environment[String(format: "key_%02d", index)] = "value\u{0000}\(index)"
        }
        let request = try composer.makeRequest(environment: environment)

        #expect(request.environment.count == IssueReportComposer.maxEnvironmentEntries)
        #expect(request.environment["key_00"] == "value0")
        #expect(request.environment["key_49"] == nil)
    }

    @Test("remove deletes app-temporary files only")
    func removeDeletesTemporaryFilesOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appending(path: "tmp")
        let composer = IssueReportComposer(temporaryDirectory: temporary)

        let notes = try write("notes.txt", Data("hello".utf8), in: directory)
        composer.addAttachments([notes])
        try composer.addImageData(Self.pngBytes, preferredExtension: "png")
        try composer.addImageData(Self.pngBytes, preferredExtension: ".JPEG")
        try composer.addImageData(Self.pngBytes, preferredExtension: "exe")

        #expect(composer.attachments.map(\.filename) == ["notes.txt", "pasted-image-1.png", "pasted-image-2.jpeg", "pasted-image-3.png"])
        let pasted = composer.attachments[1]
        #expect(pasted.ownership == .appTemporary)
        #expect(pasted.isImage)
        #expect(pasted.byteCount == Int64(Self.pngBytes.count))
        #expect(pasted.url.deletingLastPathComponent().standardizedFileURL == temporary.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: pasted.url.path))

        composer.remove(pasted.id)
        #expect(!FileManager.default.fileExists(atPath: pasted.url.path))
        #expect(composer.attachments.map(\.filename) == ["notes.txt", "pasted-image-2.jpeg", "pasted-image-3.png"])

        composer.remove(composer.attachments[0].id)
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(composer.attachments.map(\.filename) == ["pasted-image-2.jpeg", "pasted-image-3.png"])

        composer.remove(UUID())
        #expect(composer.attachments.count == 2)

        composer.discardTemporaryFiles()
        #expect(composer.attachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    @Test("Image data is rejected when empty or over the limit")
    func addImageDataValidation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        #expect(throws: IssueReportComposerError.emptyImage) {
            try composer.addImageData(Data(), preferredExtension: "png")
        }

        composer.capabilities = IssueReportCapabilities(available: true, maxAttachmentBytes: 4)
        #expect(throws: IssueReportComposerError.imageTooLarge(maximumBytes: 4)) {
            try composer.addImageData(Self.pngBytes, preferredExtension: "png")
        }
        #expect(composer.attachments.isEmpty)

        // A policy rejection after the write cleans the temporary file up again.
        composer.capabilities = IssueReportCapabilities(available: true, maxAttachments: 1)
        try composer.addImageData(Self.pngBytes, preferredExtension: "png")
        try composer.addImageData(Self.pngBytes, preferredExtension: "png")
        #expect(composer.attachments.count == 1)
        #expect(composer.attachmentError == "Attach up to 1 files per report.")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "tmp").path)
        #expect(leftovers == ["pasted-image-1.png"])
    }

    @Test("submit tracks the phase through success and failure")
    func submitPhases() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "IssueReportComposerTests.submitPhases.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        composer.machineID = "machine-1"
        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        composer.title = "Title"
        composer.body = "Body"

        var seen: [(IssueReportRequest, String)] = []
        await composer.submit(environment: ["client": "herdr-companion-mac"]) { request, machineID in
            seen.append((request, machineID))
            return Self.record
        }
        #expect(composer.phase == .submitted(Self.record))
        #expect(composer.submittedRecord == Self.record)
        #expect(seen.count == 1)
        #expect(seen.first?.1 == "machine-1")
        #expect(seen.first?.0.title == "Title")
        #expect(seen.first?.0.environment == ["client": "herdr-companion-mac"])
        #expect(!composer.canSubmit)

        composer.phase = .editing
        await composer.submit(environment: [:]) { _, _ in
            throw APIError.server(status: 426, message: "Update the companion server to file bug reports and feature requests from the app.")
        }
        #expect(composer.phase == .failed("Update the companion server to file bug reports and feature requests from the app."))
        #expect(composer.failureMessage?.contains("Update the companion server") == true)
        #expect(composer.canSubmit)

        // A draft that no longer validates is left untouched.
        composer.phase = .submitting
        await composer.submit(environment: [:]) { _, _ in
            Issue.record("Submission should not run while another is in flight")
            return Self.record
        }
        #expect(composer.phase == .submitting)
    }

    @Test("The client report id survives failed attempts and is replaced after success")
    func clientReportIdLifecycle() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "IssueReportComposerTests.clientReportId.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        composer.machineID = "machine-1"
        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        composer.title = "Title"
        composer.body = "Body"

        let first = composer.clientReportId
        #expect(Self.isValidClientReportId(first))
        #expect(first.count == 36)
        #expect(first == first.lowercased())
        #expect(Self.isValidClientReportId(IssueReportComposer.makeClientReportId()))
        #expect(IssueReportComposer.makeClientReportId() != IssueReportComposer.makeClientReportId())
        #expect(
            IssueReportComposer(
                temporaryDirectory: directory.appending(path: "other"),
                userDefaults: defaults
            ).clientReportId != first
        )
        #expect(try composer.makeRequest(environment: [:]).clientReportId == first)

        // A timeout means the issue may already exist: "Try again" must repeat
        // the id so the server can replay instead of filing a duplicate.
        var sent: [String] = []
        await composer.submit(environment: [:]) { request, _ in
            sent.append(request.clientReportId)
            throw URLError(.timedOut)
        }
        #expect(composer.phase == .failed(IssueReportComposer.ambiguousOutcomeMessage))
        #expect(composer.clientReportId == first)
        #expect(try composer.makeRequest(environment: [:]).clientReportId == first)

        // Edits between attempts and ordinary server errors keep it too.
        composer.body = "Body, with more detail"
        await composer.submit(environment: [:]) { request, _ in
            sent.append(request.clientReportId)
            throw APIError.server(status: 502, message: "gh issue create failed")
        }
        #expect(composer.phase == .failed("gh issue create failed"))
        #expect(composer.clientReportId == first)

        // The retry that succeeds still carries the original id; only then
        // does the composer move on to a fresh one.
        await composer.submit(environment: [:]) { request, _ in
            sent.append(request.clientReportId)
            return Self.record
        }
        #expect(composer.phase == .submitted(Self.record))
        #expect(sent == [first, first, first])
        let second = composer.clientReportId
        #expect(second != first)
        #expect(Self.isValidClientReportId(second))

        // A second report from the same composer never replays the first.
        composer.phase = .editing
        await composer.submit(environment: [:]) { request, _ in
            sent.append(request.clientReportId)
            return Self.record
        }
        #expect(composer.phase == .submitted(Self.record))
        #expect(sent.last == second)
        #expect(composer.clientReportId != second)
        #expect(composer.clientReportId != first)
        #expect(Set(sent).count == 2)
    }

    @Test("Timeouts and lost connections warn that the issue may already exist")
    func ambiguousFailures() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "IssueReportComposerTests.ambiguous.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        composer.machineID = "machine-1"
        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        composer.title = "Title"
        composer.body = "Body"

        await composer.submit(environment: [:]) { _, _ in throw URLError(.timedOut) }
        #expect(composer.phase == .failed(IssueReportComposer.ambiguousOutcomeMessage))

        composer.phase = .editing
        await composer.submit(environment: [:]) { _, _ in throw URLError(.networkConnectionLost) }
        #expect(composer.failureMessage == IssueReportComposer.ambiguousOutcomeMessage)

        // A connection that never reached the server is an ordinary failure.
        composer.phase = .editing
        await composer.submit(environment: [:]) { _, _ in throw URLError(.cannotConnectToHost) }
        #expect(composer.failureMessage == URLError(.cannotConnectToHost).localizedDescription)
        #expect(composer.failureMessage != IssueReportComposer.ambiguousOutcomeMessage)
        #expect(!IssueReportComposer.ambiguousOutcomeMessage.contains("http"))
    }

    @Test("Title and description lengths are counted in Unicode scalars like the server")
    func lengthsCountScalars() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))
        composer.machineID = "machine-1"
        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        composer.body = "Body"

        let thumbsUp = "👍🏽" // one grapheme cluster, two scalars
        #expect(thumbsUp.count == 1)
        #expect(thumbsUp.unicodeScalars.count == 2)

        composer.title = String(repeating: thumbsUp, count: 100) // 200 scalars
        #expect(composer.canSubmit)
        #expect(composer.titleCharacterCount == 200)
        #expect(try composer.makeRequest(environment: [:]).title.unicodeScalars.count == 200)

        composer.title = String(repeating: thumbsUp, count: 101) // 101 graphemes, 202 scalars
        #expect(composer.title.count <= IssueReportComposer.maxTitleCharacters)
        #expect(!composer.canSubmit)
        #expect(composer.titleCharacterCount == 202)
        #expect(throws: IssueReportComposerError.titleTooLong(maximum: 200)) {
            try composer.makeRequest(environment: [:])
        }

        composer.title = "Title"
        composer.body = String(repeating: thumbsUp, count: 10_000) // 20 000 scalars
        #expect(composer.canSubmit)
        composer.body = String(repeating: thumbsUp, count: 10_001)
        #expect(composer.body.count <= IssueReportComposer.maxBodyCharacters)
        #expect(!composer.canSubmit)
        #expect(throws: IssueReportComposerError.descriptionTooLong(maximum: 20_000)) {
            try composer.makeRequest(environment: [:])
        }
    }

    @Test("Control characters are folded out of the title and refused in the description")
    func controlCharacters() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))
        composer.machineID = "machine-1"
        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        composer.body = "Body"

        composer.title = "Crash\twhen\u{1B}saving\u{7F}\u{2028}now "
        #expect(composer.canSubmit)
        #expect(try composer.makeRequest(environment: [:]).title == "Crash when saving  now")
        #expect(IssueReportComposer.normalizedTitle("\u{0}a\r\nb\u{85}c") == "a  b c")

        composer.title = "Title"
        composer.body = "\u{1B}[31mred\u{1B}[0m"
        #expect(!composer.canSubmit)
        #expect(composer.descriptionProblem == IssueReportComposerError.descriptionHasControlCharacters.errorDescription)
        #expect(throws: IssueReportComposerError.descriptionHasControlCharacters) {
            try composer.makeRequest(environment: [:])
        }

        for body in ["page\u{0C}break", "nul\u{0}", "del\u{7F}"] {
            composer.body = body
            #expect(!composer.canSubmit, "\(body.debugDescription) should be refused")
            #expect(composer.descriptionProblem != nil)
        }

        // Tabs, newlines and carriage returns are the server's allowed controls.
        composer.body = "tabs\tand\r\nnewlines are fine\n"
        #expect(composer.canSubmit)
        #expect(composer.descriptionProblem == nil)
        #expect(try composer.makeRequest(environment: [:]).body == "tabs\tand\r\nnewlines are fine")

        #expect(!IssueReportComposer.containsDisallowedControlCharacters("plain 🚀 text"))
        #expect(IssueReportComposer.containsDisallowedControlCharacters("\u{1F}"))
    }

    @Test("Filenames follow the server's rules before anything is uploaded")
    func filenameRules() throws {
        #expect(IssueReportComposer.filenameProblem("shot.png") == nil)
        #expect(IssueReportComposer.filenameProblem(String(repeating: "a", count: 196) + ".png") == nil) // 200
        #expect(IssueReportComposer.filenameProblem(String(repeating: "a", count: 197) + ".png") != nil) // 201
        // 118 astral scalars + ".png": 122 scalars but exactly 240 UTF-16 units.
        #expect(IssueReportComposer.filenameProblem(String(repeating: "𝒜", count: 118) + ".png") == nil)
        #expect(IssueReportComposer.filenameProblem(String(repeating: "𝒜", count: 119) + ".png") != nil)
        #expect(IssueReportComposer.filenameProblem("log\\2026.txt") != nil)
        #expect(IssueReportComposer.filenameProblem("nul\u{0}.txt") != nil)
        #expect(IssueReportComposer.filenameProblem("two\nlines.txt") != nil)
        #expect(IssueReportComposer.filenameProblem("..") != nil)
        #expect(IssueReportComposer.filenameProblem("   ") != nil)

        // Through the queue, with a name macOS allows but the server rejects.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))
        let backslash = try write("log\\2026.txt", Data("x".utf8), in: directory)
        composer.addAttachments([backslash])
        #expect(composer.attachments.isEmpty)
        #expect(composer.attachmentError == "log\\2026.txt has characters in its name that can't be uploaded (such as a backslash). Rename it and attach it again.")

        let long = try write(String(repeating: "s", count: 201) + ".txt", Data("x".utf8), in: directory)
        composer.addAttachments([long])
        #expect(composer.attachments.isEmpty)
        #expect(composer.attachmentError?.hasSuffix("has a name longer than 200 characters. Rename it and attach it again.") == true)
    }

    @Test("A drop batch keeps its rejection while queuing the good files")
    func mixedBatchImport() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        let archive = try write("archive.zip", Data([0x50, 0x4B]), in: directory)
        let shot = try write("shot.png", Self.pngBytes, in: directory)
        await composer.importProviders([Self.fileProvider(archive), Self.fileProvider(shot)])
        #expect(composer.attachments.map(\.filename) == ["shot.png"])
        #expect(composer.attachments[0].ownership == .userSelected)
        #expect(composer.attachmentError == "archive.zip isn't a supported file type.")

        // Image data after a rejected file keeps the message too.
        composer.attachmentError = nil
        let oversize = try write("oversize.log", Data(repeating: 0x41, count: 13), in: directory)
        // 12 bytes keeps the queued shot.png; the 13-byte log is over.
        composer.capabilities = IssueReportCapabilities(available: true, maxAttachmentBytes: 12, maxTotalAttachmentBytes: 100)
        #expect(composer.attachments.map(\.filename) == ["shot.png"])
        await composer.importProviders([Self.fileProvider(oversize), Self.dataProvider(Data([0x89, 0x50, 0x4E, 0x47]), type: .png)])
        #expect(composer.attachments.map(\.filename) == ["shot.png", "pasted-image-1.png"])
        #expect(composer.attachmentError == "oversize.log is larger than the file limit of 12 bytes.")

        // A fresh batch with nothing wrong clears the stale message.
        let notes = try write("notes.txt", Data("hi".utf8), in: directory)
        await composer.importProviders([Self.fileProvider(notes)])
        #expect(composer.attachmentError == nil)
        #expect(composer.attachments.count == 3)

        // Providers without a file or image are not an import at all.
        #expect(!composer.importItemProviders([NSItemProvider(object: "text" as NSString)]))
    }

    @Test("Pasted TIFF data is re-encoded as PNG so GitHub renders it inline")
    func tiffImportBecomesPNG() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        let tiff = try #require(Self.makeBitmap().representation(using: .tiff, properties: [:]))
        await composer.importProviders([Self.dataProvider(tiff, type: .tiff)])
        #expect(composer.attachments.map(\.filename) == ["pasted-image-1.png"])
        #expect(composer.attachments[0].ownership == .appTemporary)
        #expect(composer.attachments[0].isImage)
        let written = try Data(contentsOf: composer.attachments[0].url)
        #expect(written.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        // PNG and JPEG bytes pass through untouched.
        let png = try #require(Self.makeBitmap().representation(using: .png, properties: [:]))
        let converted = IssueReportComposer.attachableImage(from: png, type: .png)
        #expect(converted.data == png)
        #expect(converted.extension == "png")
        let jpeg = IssueReportComposer.attachableImage(from: Data([0xFF, 0xD8]), type: .jpeg)
        #expect(jpeg.extension == "jpeg" || jpeg.extension == "jpg")
    }

    @Test("Nothing is written after the sheet discarded its files")
    func discardStopsLateWrites() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appending(path: "tmp")
        let composer = IssueReportComposer(temporaryDirectory: temporary)

        try composer.addImageData(Self.pngBytes, preferredExtension: "png")
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        composer.discardTemporaryFiles()
        #expect(composer.isDiscarded)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))

        // The slow paste that completes after the sheet closed.
        #expect(throws: IssueReportComposerError.sheetClosed) {
            try composer.addImageData(Self.pngBytes, preferredExtension: "png")
        }
        await composer.importProviders([Self.dataProvider(Self.pngBytes, type: .png)])
        #expect(!composer.importPasteboardImage(NSPasteboard.withUniqueName()))
        #expect(composer.attachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test("Stale temporary folders are swept at launch and fresh ones kept")
    func staleTemporaryDirectorySweep() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = root.appending(path: "herdr-issue-report-old", directoryHint: .isDirectory)
        let fresh = root.appending(path: "herdr-issue-report-fresh", directoryHint: .isDirectory)
        let other = root.appending(path: "herdr-voice-old", directoryHint: .isDirectory)
        let file = root.appending(path: "herdr-issue-report-note.txt")
        for folder in [old, fresh, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: old.appending(path: "pasted-image-1.png"))
        try Data("x".utf8).write(to: file)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 60 * 60)
        for url in [old, other, file] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: url.path)
        }

        IssueReportComposer.removeStaleTemporaryDirectories(in: root, now: now)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: file.path))

        // A missing root is not an error.
        IssueReportComposer.removeStaleTemporaryDirectories(in: root.appending(path: "missing"), now: now)
    }

    @Test("Lowered server limits drop queued files that no longer fit")
    func loweredLimitsTrimQueue() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = IssueReportComposer(temporaryDirectory: directory.appending(path: "tmp"))

        let first = try write("first.log", Data(repeating: 0x41, count: 5), in: directory)
        let second = try write("second.log", Data(repeating: 0x41, count: 5), in: directory)
        composer.addAttachments([first, second])
        try composer.addImageData(Self.pngBytes, preferredExtension: "png")
        #expect(composer.attachments.count == 3)
        let pasted = composer.attachments[2].url

        composer.capabilities = IssueReportCapabilities(available: true, maxTotalAttachmentBytes: 8)
        #expect(composer.attachments.map(\.filename) == ["first.log"])
        #expect(composer.attachmentError == "second.log, pasted-image-1.png no longer fit this machine's report limits (up to 6 files, 20 MB each, 8 bytes in total) and were removed.")
        #expect(!FileManager.default.fileExists(atPath: pasted.path))
        #expect(FileManager.default.fileExists(atPath: second.path))

        // Limits that still fit leave the queue and the message alone.
        composer.attachmentError = nil
        composer.capabilities = IssueReportCapabilities(available: true, maxAttachments: 1, maxAttachmentBytes: 5, maxTotalAttachmentBytes: 5)
        #expect(composer.attachments.map(\.filename) == ["first.log"])
        #expect(composer.attachmentError == nil)

        composer.capabilities = IssueReportCapabilities(available: true, maxAttachmentBytes: 4)
        #expect(composer.attachments.isEmpty)
        #expect(composer.attachmentError == "first.log no longer fits this machine's report limits (up to 6 files, 4 bytes each, 40 MB in total) and was removed.")
    }

    @Test("Photos lose Exif and GPS metadata before upload, other files stay byte-identical")
    func stripsPhotoMetadata() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "IssueReportComposerTests.metadata.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        composer.machineID = "machine-1"
        composer.capabilities = IssueReportCapabilities(available: true, repository: "owner/repo")
        composer.title = "Title"
        composer.body = "Body"

        let jpeg = try Self.makeJPEG(withMetadata: true)
        #expect(Self.gpsDictionary(in: jpeg) != nil)
        #expect(Self.exifUserComment(in: jpeg) == "taken at home")
        let photo = try write("photo.jpg", jpeg, in: directory)
        let text = try write("notes.txt", Data("hello".utf8), in: directory)
        composer.addAttachments([photo, text])

        let request = try composer.makeRequest(environment: [:])
        #expect(request.attachments.map(\.filename) == ["photo.jpg", "notes.txt"])
        #expect(request.attachments.map(\.contentType) == ["image/jpeg", "text/plain"])
        let uploaded = try #require(Data(base64Encoded: request.attachments[0].dataBase64))
        #expect(Self.gpsDictionary(in: uploaded) == nil)
        #expect(Self.exifUserComment(in: uploaded) == nil)
        let source = try #require(CGImageSourceCreateWithData(uploaded as CFData, nil))
        #expect(CGImageSourceGetType(source).map { $0 as String } == UTType.jpeg.identifier)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 4)
        #expect(properties?[kCGImagePropertyPixelHeight] as? Int == 4)
        #expect(Data(base64Encoded: request.attachments[1].dataBase64) == Data("hello".utf8))

        // The off-main path used by the sheet produces the same payload.
        var sent: IssueReportRequest?
        await composer.submit(environment: [:]) { request, _ in
            sent = request
            return Self.record
        }
        #expect(composer.submittedRecord == Self.record)
        let sentPhoto = try #require(sent?.attachments.first.flatMap { Data(base64Encoded: $0.dataBase64) })
        #expect(Self.gpsDictionary(in: sentPhoto) == nil)

        // Non-photo formats and undecodable bytes are sent as they are.
        #expect(IssueReportComposer.strippingImageMetadata(Data("<svg/>".utf8), filename: "icon.svg") == nil)
        #expect(IssueReportComposer.strippingImageMetadata(Self.pngBytes, filename: "shot.png") == nil)
        #expect(IssueReportComposer.strippingImageMetadata(jpeg, filename: "photo.gif") == nil)
    }

    // MARK: - Discovery, selection and persistence

    @Test("Only live machines in a connected app are asked for capabilities")
    func connectedMachineIDsExcludeDemoAndOffline() {
        let machines = [Self.machine("alpha"), Self.machine("beta"), Self.machine("gamma")]
        let states: [String: ConnectionState] = [
            "alpha": .live,
            "beta": .connecting,
            "gamma": .disconnected,
        ]

        #expect(
            IssueReportComposer.connectedMachineIDs(
                machines: machines,
                isDemoMode: false,
                connectionState: { states[$0] ?? .disconnected }
            ) == ["alpha"]
        )
        // Demo machines are never queried, even if their state claims live.
        #expect(
            IssueReportComposer.connectedMachineIDs(
                machines: machines,
                isDemoMode: true,
                connectionState: { _ in .live }
            ).isEmpty
        )
    }

    @Test("A successful report is remembered for the next composer on this Mac")
    func successfulSubmissionRemembersMachine() async throws {
        let suite = "IssueReportComposerTests.remembered.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let machines = [Self.machine("alpha"), Self.machine("beta")]
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            machineID == "alpha" ? Self.unavailable(reason: "No repository is configured.") : Self.available()
        }
        #expect(composer.machineID == "beta")
        #expect(composer.selectedMachineAvailable)
        #expect(composer.capabilities?.repository == "owner/repo")
        #expect(composer.noAvailableMachineExplanation == nil)
        #expect(composer.machineStatusLabel(for: "beta") == nil)
        #expect(composer.machineStatusLabel(for: "alpha") == "Unavailable")

        composer.title = "Title"
        composer.body = "Body"
        #expect(composer.canSubmit)
        await composer.submit(environment: [:]) { _, machineID in
            #expect(machineID == "beta")
            return Self.record
        }
        #expect(composer.phase == .submitted(Self.record))
        #expect(defaults.string(forKey: IssueReportComposer.lastSuccessfulMachineIDKey) == "beta")

        // The next sheet on this Mac defaults to the remembered companion even
        // though another available machine comes first in roster order.
        let next = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp-next"),
            userDefaults: defaults
        )
        #expect(next.lastSuccessfulMachineID == "beta")
        await next.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            Self.available(repository: "owner/\(machineID)")
        }
        #expect(next.machineID == "beta")
        #expect(next.capabilities?.repository == "owner/beta")
    }

    @Test("Picking, discovery and failed sends leave the remembered companion alone")
    func rememberedMachineChangesOnlyAfterSuccess() async throws {
        let suite = "IssueReportComposerTests.rememberedFailures.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("alpha", forKey: IssueReportComposer.lastSuccessfulMachineIDKey)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let machines = [Self.machine("alpha"), Self.machine("beta")]
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        #expect(composer.lastSuccessfulMachineID == "alpha")

        // Alpha is remembered but unavailable now, so the first available peer
        // wins; neither opening nor picking writes the preference.
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            machineID == "alpha" ? Self.unavailable() : Self.available()
        }
        #expect(composer.machineID == "beta")
        #expect(defaults.string(forKey: IssueReportComposer.lastSuccessfulMachineIDKey) == "alpha")

        composer.title = "Title"
        composer.body = "Body"
        await composer.submit(environment: [:]) { _, _ in
            throw APIError.server(status: 502, message: "gh issue create failed")
        }
        #expect(composer.phase == .failed("gh issue create failed"))
        #expect(defaults.string(forKey: IssueReportComposer.lastSuccessfulMachineIDKey) == "alpha")

        await composer.submit(environment: [:]) { _, machineID in
            #expect(machineID == "beta")
            return Self.record
        }
        #expect(defaults.string(forKey: IssueReportComposer.lastSuccessfulMachineIDKey) == "beta")
    }

    @Test("An unavailable selection cannot submit even when a peer is available")
    func unavailableSelectionBlocksSubmission() async throws {
        let suite = "IssueReportComposerTests.gating.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        await composer.discover(
            machines: [Self.machine("alpha"), Self.machine("beta")],
            connectedIDs: ["alpha", "beta"]
        ) { machineID in
            machineID == "alpha" ? Self.available() : Self.unavailable(reason: "No repository is configured.")
        }
        #expect(composer.machineID == "alpha")
        composer.title = "Title"
        composer.body = "Body"
        #expect(composer.canSubmit)

        composer.machineID = "beta"
        #expect(!composer.canSubmit)
        #expect(!composer.selectedMachineAvailable)
        #expect(composer.selectedMachineReason == "No repository is configured.")
        var sent = false
        await composer.submit(environment: [:]) { _, _ in
            sent = true
            return Self.record
        }
        #expect(!sent)
        #expect(composer.phase == .editing)

        composer.machineID = "alpha"
        #expect(composer.canSubmit)
    }

    @Test("Selected capabilities, notices and limits change with the picker")
    func selectedLimitsFollowPickerSelection() async throws {
        let suite = "IssueReportComposerTests.limits.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        await composer.discover(
            machines: [Self.machine("alpha"), Self.machine("beta")],
            connectedIDs: ["alpha", "beta"]
        ) { machineID in
            machineID == "alpha"
                ? IssueReportCapabilities(
                    available: true,
                    repository: "owner/alpha",
                    maxAttachments: 1,
                    maxAttachmentBytes: 8,
                    maxTotalAttachmentBytes: 8
                )
                : IssueReportCapabilities(
                    available: true,
                    repository: "owner/beta",
                    maxAttachments: 6,
                    maxAttachmentBytes: 8,
                    maxTotalAttachmentBytes: 16
                )
        }
        #expect(composer.machineID == "alpha")
        #expect(composer.capabilities?.repository == "owner/alpha")
        #expect(composer.effectiveMaxAttachments == 1)

        composer.machineID = "beta"
        #expect(composer.capabilities?.repository == "owner/beta")
        #expect(composer.effectiveMaxAttachments == 6)
        let first = try write("first.log", Data([0x41]), in: directory)
        let second = try write("second.log", Data([0x41]), in: directory)
        composer.addAttachments([first, second])
        #expect(composer.attachments.count == 2)

        composer.machineID = "alpha"
        #expect(composer.capabilities?.repository == "owner/alpha")
        #expect(composer.effectiveMaxAttachments == 1)
        #expect(composer.attachments.map(\.filename) == ["first.log"])
        #expect(composer.attachmentError?.contains("no longer fits") == true)
    }

    @Test("A superseded discovery cannot overwrite newer results or limits")
    func supersededDiscoveryCannotOverwrite() async throws {
        let suite = "IssueReportComposerTests.superseded.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        let gate = TestGate()
        let stale = Task {
            await composer.discover(machines: [Self.machine("alpha")], connectedIDs: ["alpha"]) { _ in
                await gate.wait()
                return IssueReportCapabilities(
                    available: true,
                    repository: "owner/stale",
                    maxAttachments: 1,
                    maxAttachmentBytes: 8,
                    maxTotalAttachmentBytes: 8
                )
            }
        }
        await gate.waitForArrival()

        // Draft editing stays live while a sweep runs, but submission waits.
        composer.title = "Title"
        composer.body = "Body"
        #expect(composer.isDiscoveringReports)
        #expect(!composer.canSubmit)
        // The same control stays reachable so a sweep can be superseded.
        #expect(composer.canCheckAgain)

        // A newer pass settles first.
        await composer.discover(machines: [Self.machine("alpha")], connectedIDs: ["alpha"]) { _ in
            IssueReportCapabilities(
                available: true,
                repository: "owner/fresh",
                maxAttachments: 5,
                maxAttachmentBytes: 8,
                maxTotalAttachmentBytes: 40
            )
        }
        #expect(composer.capabilities?.repository == "owner/fresh")
        #expect(composer.effectiveMaxAttachments == 5)
        #expect(!composer.isDiscoveringReports)

        // The stale pass must not overwrite the fresh state when it finally answers.
        await gate.release()
        await stale.value
        #expect(composer.capabilities?.repository == "owner/fresh")
        #expect(composer.effectiveMaxAttachments == 5)
        #expect(composer.machineChecks["alpha"] == .loaded(IssueReportCapabilities(
            available: true,
            repository: "owner/fresh",
            maxAttachments: 5,
            maxAttachmentBytes: 8,
            maxTotalAttachmentBytes: 40
        )))
    }

    @Test("A cancelled sweep settles as a failed check instead of a false verdict")
    func cancelledDiscoverySettlesAsFailure() async throws {
        let suite = "IssueReportComposerTests.cancelled.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        let gate = TestGate()
        let cancelled = Task {
            await composer.discover(machines: [Self.machine("alpha")], connectedIDs: ["alpha"]) { _ in
                await gate.wait()
                throw CancellationError()
            }
        }
        await gate.waitForArrival()
        #expect(composer.isDiscoveringReports)

        // Cancelling the sweep and releasing the stub settles every machine as
        // checked-and-failed: nothing stays at "Checking…", the explanation is
        // reachable, and submission stays blocked for the selected machine.
        cancelled.cancel()
        await gate.release()
        await cancelled.value

        #expect(!composer.isDiscoveringReports)
        #expect(composer.machineChecks["alpha"] == .failed(message: IssueReportMachineSelection.unreachableMessage))
        #expect(composer.machineStatusLabel(for: "alpha") == "Check failed")
        #expect(composer.selectedMachineReason == IssueReportMachineSelection.unreachableMessage)
        #expect(composer.noAvailableMachineExplanation != nil)
        #expect(!composer.canSubmit)
    }

    @Test("A disconnect or removal invalidates the cached answer before submission")
    func refreshInvalidatesStaleSelection() async throws {
        let suite = "IssueReportComposerTests.refresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let machines = [Self.machine("alpha"), Self.machine("beta")]
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            Self.available(repository: "owner/\(machineID)")
        }
        #expect(composer.machineID == "alpha")
        composer.title = "Title"
        composer.body = "Body"
        #expect(composer.canSubmit)

        // Alpha drops off while beta is still live: the explicit alpha pick is
        // kept, so submission stays blocked and its stale answer is gone.
        composer.refreshAvailability(machines: machines, connectedIDs: ["beta"])
        #expect(composer.machineID == "alpha")
        #expect(!composer.canSubmit)
        #expect(composer.capabilities == nil)
        #expect(composer.machineChecks["alpha"] == .disconnected)
        #expect(composer.selectedMachineReason == IssueReportMachineSelection.disconnectedMessage)

        var sent = false
        await composer.submit(environment: [:]) { _, _ in
            sent = true
            return Self.record
        }
        #expect(!sent)
        #expect(composer.phase == .editing)

        // Alpha is unpaired: the selection falls back to the first paired machine.
        composer.refreshAvailability(machines: [Self.machine("beta")], connectedIDs: ["beta"])
        #expect(composer.machineID == "beta")
        #expect(composer.machineChecks["alpha"] == nil)
    }

    @Test("A removed companion is not silently swapped in for the reviewed submission")
    func removedCompanionCannotBeSilentlyReplaced() async throws {
        let suite = "IssueReportComposerTests.destination.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let machines = [Self.machine("alpha"), Self.machine("beta")]
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            Self.available(repository: "owner/\(machineID)")
        }
        #expect(composer.machineID == "alpha")
        #expect(composer.capabilities?.repository == "owner/alpha")
        composer.title = "Title"
        composer.body = "Body"
        #expect(composer.canSubmit)

        // Alpha is removed in Settings while Beta stays available. Refreshing
        // would silently select Beta and file through owner/beta, which the
        // user never reviewed, so the reviewed submission is refused.
        let alphaRemoved = [Self.machine("beta")]
        #expect(!composer.prepareSubmission(machines: alphaRemoved, connectedIDs: ["beta"]))
        #expect(composer.machineID == "beta")
        #expect(composer.capabilities?.repository == "owner/beta")

        // Beta's machine and repository notice are now on screen, so an
        // explicit second click proceeds through Beta.
        #expect(composer.prepareSubmission(machines: alphaRemoved, connectedIDs: ["beta"]))
        var sentThrough: String?
        await composer.submit(environment: [:]) { _, machineID in
            sentThrough = machineID
            return Self.record
        }
        #expect(sentThrough == "beta")
        #expect(composer.phase == .submitted(Self.record))
        #expect(defaults.string(forKey: IssueReportComposer.lastSuccessfulMachineIDKey) == "beta")
    }

    @Test("A reviewed companion that disappears from the roster cannot submit")
    func emptiedRosterBlocksReviewedSubmission() async throws {
        let suite = "IssueReportComposerTests.emptied.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        await composer.discover(machines: [Self.machine("alpha")], connectedIDs: ["alpha"]) { _ in
            Self.available(repository: "owner/alpha")
        }
        composer.title = "Title"
        composer.body = "Body"
        #expect(composer.canSubmit)

        // The only paired companion is unpaired: the selection clears and the
        // reviewed submission has nowhere to go.
        #expect(!composer.prepareSubmission(machines: [], connectedIDs: []))
        #expect(composer.machineID.isEmpty)
        #expect(!composer.canSubmit)
    }

    @Test("Check again recovers an unavailable selection while a peer stays available")
    func recheckRecoversUnavailableSelection() async throws {
        let suite = "IssueReportComposerTests.recheck.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let machines = [Self.machine("alpha"), Self.machine("beta")]
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        // Beta is disconnected, so only Alpha answers available.
        await composer.discover(machines: machines, connectedIDs: ["alpha"]) { machineID in
            Self.available(repository: "owner/\(machineID)")
        }
        #expect(composer.machineID == "alpha")

        // The user selects the unavailable Beta to read its reason; submission
        // stays blocked even though Alpha can file.
        composer.machineID = "beta"
        #expect(composer.selectedMachineReason == IssueReportMachineSelection.disconnectedMessage)
        composer.title = "Title"
        composer.body = "Body"
        #expect(!composer.canSubmit)
        #expect(composer.canCheckAgain)
        #expect(!composer.prepareSubmission(machines: machines, connectedIDs: ["alpha"]))

        // Beta reconnects and Check again re-asks every connected companion
        // without losing the draft. Beta is now selectable and can file.
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            Self.available(repository: "owner/\(machineID)")
        }
        #expect(composer.title == "Title")
        #expect(composer.body == "Body")
        #expect(composer.machineChecks["beta"] == .loaded(Self.available(repository: "owner/beta")))
        #expect(composer.machineStatusLabel(for: "beta") == nil)
        // Deterministic selection returns to the first available in roster
        // order, and a second pick of the recovered Beta can file.
        #expect(composer.machineID == "alpha")
        composer.machineID = "beta"
        #expect(composer.canSubmit)
        #expect(composer.prepareSubmission(machines: machines, connectedIDs: ["alpha", "beta"]))
        var sentThrough: String?
        await composer.submit(environment: [:]) { _, machineID in
            sentThrough = machineID
            return Self.record
        }
        #expect(sentThrough == "beta")
    }

    @Test("Check again recovers a failed companion while a peer stays available")
    func recheckRecoversFailedSelection() async throws {
        let suite = "IssueReportComposerTests.recheckFailed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let machines = [Self.machine("alpha"), Self.machine("beta")]
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        // Beta is connected but its check fails, while Alpha answers available.
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            guard machineID == "alpha" else { throw URLError(.cannotConnectToHost) }
            return Self.available(repository: "owner/alpha")
        }
        #expect(composer.machineChecks["beta"] == .failed(message: IssueReportMachineSelection.unreachableMessage))

        composer.machineID = "beta"
        #expect(composer.selectedMachineReason == IssueReportMachineSelection.unreachableMessage)
        composer.title = "Title"
        composer.body = "Body"
        #expect(!composer.canSubmit)

        // The companion is fixed and Check again recovers it without losing
        // the draft.
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { machineID in
            Self.available(repository: "owner/\(machineID)")
        }
        #expect(composer.machineChecks["beta"] == .loaded(Self.available(repository: "owner/beta")))
        composer.machineID = "beta"
        #expect(composer.canSubmit)
    }

    @Test("An in-flight submission keeps the companion it captured")
    func submissionKeepsCapturedMachine() async throws {
        let suite = "IssueReportComposerTests.captured.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Gates the attachment-encoding await so the selection change below is
        // applied deterministically between the capture and the send.
        let gate = TestGate()
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults,
            encodeAttachments: { _, _ in
                await gate.wait()
                return []
            }
        )
        await composer.discover(
            machines: [Self.machine("alpha"), Self.machine("beta")],
            connectedIDs: ["alpha", "beta"]
        ) { machineID in
            Self.available(repository: "owner/\(machineID)")
        }
        #expect(composer.machineID == "alpha")
        composer.title = "Title"
        composer.body = "Body"

        let submission = Task {
            await composer.submit(environment: [:]) { _, machineID in
                #expect(machineID == "alpha")
                return Self.record
            }
        }
        // While encoding is held, switch the picker; the request and the
        // remembered id must stay with the captured companion.
        await gate.waitForArrival()
        #expect(composer.isSubmitting)
        composer.machineID = "beta"
        await gate.release()
        await submission.value

        #expect(composer.phase == .submitted(Self.record))
        #expect(composer.machineID == "beta")
        #expect(defaults.string(forKey: IssueReportComposer.lastSuccessfulMachineIDKey) == "alpha")
    }

    @Test("The no-available explanation names machines, distinguishes skipped ones and links setup")
    func noAvailableExplanation() async throws {
        let suite = "IssueReportComposerTests.explanation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let machines = [
            Self.machine("alpha", name: "Alpha"),
            Self.machine("beta", name: "Beta"),
            Self.machine("gamma", name: "Gamma"),
        ]
        let composer = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp"),
            userDefaults: defaults
        )
        await composer.discover(machines: machines, connectedIDs: ["alpha", "beta"]) { _ in
            Self.unavailable(reason: "Set code_factory.repository in the private configuration (owner/repo) to file issues from the app")
        }
        #expect(composer.showsMachinePicker)
        #expect(!composer.hasAvailableMachine)
        #expect(composer.checkedMachineNames == ["Alpha", "Beta"])
        #expect(composer.uncheckedMachineNames == ["Gamma"])
        #expect(composer.machineStatusLabel(for: "alpha") == "Unavailable")
        #expect(composer.machineStatusLabel(for: "gamma") == "Disconnected")
        let explanation = try #require(composer.noAvailableMachineExplanation)
        #expect(explanation.contains("Alpha"))
        #expect(explanation.contains("Beta"))
        #expect(explanation.contains("Gamma"))
        #expect(explanation.contains("not checked"))
        #expect(explanation.contains("[code_factory]"))
        #expect(explanation.contains("gh"))
        #expect(!explanation.contains("still try"))
        #expect(
            IssueReportComposer.codeFactoryDocsURL.absoluteString
                == "https://github.com/ronnie3786/herdr-companion/blob/main/docs/code-factory.md"
        )

        // An all-disconnected roster explains connection recovery instead of
        // server configuration, and still names the machines skipped.
        let offline = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp-offline"),
            userDefaults: defaults
        )
        await offline.discover(machines: machines, connectedIDs: []) { _ in
            Issue.record("Disconnected machines must not be queried")
            return Self.available()
        }
        let offlineExplanation = try #require(offline.noAvailableMachineExplanation)
        #expect(offlineExplanation.contains("not checked"))
        #expect(offlineExplanation.contains("Alpha"))
        #expect(offlineExplanation.contains("connect"))
        #expect(!offlineExplanation.contains("[code_factory]"))

        // One paired machine hides the picker, but its unavailable reason
        // still shows and its explanation still replaces the submit controls.
        let single = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp-single"),
            userDefaults: defaults
        )
        await single.discover(machines: [Self.machine("alpha", name: "Alpha")], connectedIDs: ["alpha"]) { _ in
            Self.unavailable(reason: "No repository is configured on this server.")
        }
        #expect(!single.showsMachinePicker)
        #expect(single.selectedMachineReason == "No repository is configured on this server.")
        #expect(single.noAvailableMachineExplanation != nil)

        // An empty roster has no selection, no explanation, and keeps the
        // Settings guidance to itself.
        let empty = IssueReportComposer(
            temporaryDirectory: directory.appending(path: "tmp-empty"),
            userDefaults: defaults
        )
        await empty.discover(machines: [], connectedIDs: []) { _ in
            Issue.record("An empty roster must not be queried")
            return Self.available()
        }
        #expect(empty.machineID.isEmpty)
        #expect(empty.hasRunDiscovery)
        #expect(!empty.showsMachinePicker)
        #expect(empty.noAvailableMachineExplanation == nil)
    }

    // MARK: - Helpers

    private static let record = IssueReportRecord(
        id: "isr_0123456789ab",
        kind: .bug,
        title: "Title",
        autofix: true,
        issueNumber: 42,
        issueUrl: "https://github.com/owner/repo/issues/42",
        repository: "owner/repo",
        attachments: [],
        createdAt: "2026-09-18T12:00:00Z"
    )

    private static func machine(_ id: String, name: String? = nil) -> HerdrMachine {
        HerdrMachine(id: id, name: name ?? id.uppercased(), urlString: "https://\(id).example.invalid")
    }

    /// Nonisolated so the `@Sendable` capability closures passed to
    /// `discover(machines:connectedIDs:fetchCapabilities:)` can build their
    /// canned answers without hopping back to the main actor.
    nonisolated private static func available(repository: String = "owner/repo") -> IssueReportCapabilities {
        IssueReportCapabilities(available: true, repository: repository)
    }

    nonisolated private static func unavailable(reason: String? = nil) -> IssueReportCapabilities {
        IssueReportCapabilities(available: false, reason: reason)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "herdr-issue-report-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The server's rule for `clientReportId`: 8–64 ASCII letters, digits,
    /// `-` or `_` (`issue_reports._CLIENT_REPORT_ID_RE`).
    private static func isValidClientReportId(_ id: String) -> Bool {
        (8...64).contains(id.utf8.count) && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    private func write(_ name: String, _ data: Data, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// A Finder-style drop item: `public.file-url` bytes of a local file.
    private static func fileProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = url.dataRepresentation
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// A clipboard-style drop item carrying raw image bytes of `type`.
    private static func dataProvider(_ data: Data, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private static func makeBitmap() -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        for x in 0..<4 {
            for y in 0..<4 {
                bitmap.setColor(NSColor(red: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        return bitmap
    }

    /// A 4×4 JPEG carrying a GPS block and an Exif user comment, the way a
    /// phone photo does.
    private static func makeJPEG(withMetadata: Bool) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if withMetadata {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.33,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.03,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: "taken at home",
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func imageProperties(in data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private static func gpsDictionary(in data: Data) -> [CFString: Any]? {
        imageProperties(in: data)?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    private static func exifUserComment(in data: Data) -> String? {
        (imageProperties(in: data)?[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String
    }
}

/// Holds one injected asynchronous step — a capabilities request or an
/// attachment encoding — until the test releases it, so a superseding pass or
/// a selection change can be applied deterministically. No sleeps: the step
/// signals its arrival and returns as soon as its release is recorded.
private actor TestGate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}
