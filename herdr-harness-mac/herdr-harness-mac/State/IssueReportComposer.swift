import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file queued for a bug report or feature request.
///
/// User-selected files stay where they are and are read when the report is
/// sent. Pasted or dropped images are written to the composer's temporary
/// folder (`ownership == .appTemporary`) and deleted when removed or when the
/// sheet closes.
struct IssueReportAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let byteCount: Int64
    let isImage: Bool
    let ownership: AttachmentSourceOwnership
}

/// Lifecycle of one report, from the first keystroke to the filed issue.
enum IssueReportPhase: Equatable, Sendable {
    case editing
    case submitting
    case submitted(IssueReportRecord)
    case failed(String)
}

/// Problems the composer detects before anything reaches the network.
enum IssueReportComposerError: LocalizedError, Equatable, Sendable {
    case missingTitle
    case titleTooLong(maximum: Int)
    case missingDescription
    case descriptionTooLong(maximum: Int)
    case descriptionHasControlCharacters
    case noMachineSelected
    case emptyImage
    case imageTooLarge(maximumBytes: Int64)
    case attachmentUnreadable(filename: String)
    case attachmentChanged(filename: String)
    case attachmentTooLargeAfterProcessing(filename: String, maximumBytes: Int64)
    case sheetClosed

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            "Add a short title before filing the report."
        case let .titleTooLong(maximum):
            "Keep the title to \(maximum) characters."
        case .missingDescription:
            "Describe the bug or the feature before filing the report."
        case let .descriptionTooLong(maximum):
            "Keep the description to \(maximum.formatted()) characters."
        case .descriptionHasControlCharacters:
            "The description contains non-printable characters (such as terminal colour codes). Remove them to file the report."
        case .noMachineSelected:
            "Connect a companion server before filing the report."
        case .emptyImage:
            "The image is empty and cannot be attached."
        case let .imageTooLarge(maximumBytes):
            "Images must be \(maximumBytes.formatted(.byteCount(style: .file))) or smaller."
        case let .attachmentUnreadable(filename):
            "Herdr could not read \(filename). Remove it and attach it again."
        case let .attachmentChanged(filename):
            "\(filename) changed since it was attached. Remove it and attach it again."
        case let .attachmentTooLargeAfterProcessing(filename, maximumBytes):
            "\(filename) is larger than \(maximumBytes.formatted(.byteCount(style: .file))) once its metadata is removed. Export a smaller copy and attach it again."
        case .sheetClosed:
            "The report was closed before the image could be attached."
        }
    }
}

/// Draft state behind the "Report a Bug or Request a Feature" sheet.
///
/// The composer owns validation, the attachment queue, the temporary files
/// behind pasted images, and the request payload. It never talks to the
/// network itself: `submit(environment:using:)` receives the call that does,
/// so tests drive it with a stub and the view passes `HerdrAppModel`.
///
/// Validation mirrors `herdr_harness/issue_reports.py` exactly — lengths are
/// counted in Unicode scalars (Python `len`), control characters are folded
/// out of the title and refused in the body, and filenames follow
/// `agent_runs._sanitize_attachment_filename` — so a draft the sheet accepts
/// is never bounced by the server after a 40 MB upload.
@MainActor
@Observable
final class IssueReportComposer {
    typealias Phase = IssueReportPhase

    /// Client-side ceilings. The server's capabilities can lower them but never
    /// raise them; the server performs the authoritative check on submit.
    static let maxAttachments = 6
    static let maxAttachmentBytes = AttachmentPolicy.maximumFileBytes
    static let maxTotalAttachmentBytes = AttachmentPolicy.maximumAggregateBytes
    static let maxTitleCharacters = 200
    static let maxBodyCharacters = 20_000
    static let maxFilenameCharacters = 200
    static let maxFilenameUTF16Units = 240
    static let maxEnvironmentEntries = 40
    static let maxEnvironmentKeyLength = 64
    static let maxEnvironmentValueLength = 512
    static let clientIdentifier = "herdr-companion-mac"
    nonisolated static let fallbackContentType = "application/octet-stream"

    /// Folder-name prefix of every composer-owned temporary directory, so a
    /// launch-time sweep can find the ones a crash left behind.
    static let temporaryDirectoryPrefix = "herdr-issue-report-"
    static let staleTemporaryDirectoryAge: TimeInterval = 24 * 60 * 60

    /// Shown when the connection dropped after the request may have reached
    /// the server: the issue can already exist, so a blind retry would file
    /// it twice.
    static let ambiguousOutcomeMessage = "The connection dropped while the report was being filed. "
        + "It may already have been filed — check the repository's issues on GitHub before trying again."

    /// Image formats that embed Exif, GPS and XMP blocks. These are re-encoded
    /// before upload so a phone photo never publishes its location. GIF, WebP
    /// and SVG pass through unchanged: re-encoding would drop animation or
    /// vector data, and they carry no location metadata.
    nonisolated static let metadataBearingImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp"]

    /// File types the picker offers. Mirrors `HerdrAttachmentTypes` so the
    /// panel and the validation never disagree.
    static let allowedContentTypes: [UTType] = HerdrAttachmentTypes.allowedExtensions
        .sorted()
        .compactMap { UTType(filenameExtension: $0) }

    var kind: IssueReportKind = .bug
    var title = ""
    var body = ""
    var autofix = true
    var machineID = ""
    var phase: Phase = .editing
    var attachmentError: String?
    /// Server-advertised limits. Lowering them re-checks the queue: files that
    /// no longer fit are removed with a message instead of failing after upload.
    var capabilities: IssueReportCapabilities? {
        didSet { enforceLimits() }
    }
    private(set) var attachments: [IssueReportAttachment] = []
    /// Set by `discardTemporaryFiles()`; afterwards no image is ever written
    /// again, so a slow drop or paste that completes after the sheet closed
    /// cannot leave a file behind.
    @ObservationIgnored private(set) var isDiscarded = false
    /// The `clientReportId` sent with this draft. Minted once per draft and
    /// kept across failed attempts, so "Try again" after a timeout repeats the
    /// same id and the server replays the issue it may already have filed
    /// instead of opening a duplicate. Replaced only once a submission
    /// succeeds, so a second report from the same composer is never mistaken
    /// for a replay of the first.
    @ObservationIgnored private(set) var clientReportId: String

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let temporaryDirectory: URL
    @ObservationIgnored private var pastedImageCount = 0

    /// - Parameter temporaryDirectory: Where pasted images are written. Defaults
    ///   to a unique folder under the app's temporary directory; tests pass
    ///   their own so cleanup can be asserted.
    init(fileManager: FileManager = .default, temporaryDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
            ?? fileManager.temporaryDirectory.appending(
                path: "\(Self.temporaryDirectoryPrefix)\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        clientReportId = Self.makeClientReportId()
    }

    /// A fresh `clientReportId`: a lowercase UUID, 36 characters of hex digits
    /// and hyphens, inside the server's rule of 8–64 letters, digits, `-` or
    /// `_` (`issue_reports._CLIENT_REPORT_ID_RE`).
    nonisolated static func makeClientReportId() -> String {
        UUID().uuidString.lowercased()
    }

    // MARK: - Derived state

    var isSubmitting: Bool { phase == .submitting }

    var submittedRecord: IssueReportRecord? {
        if case let .submitted(record) = phase { record } else { nil }
    }

    var failureMessage: String? {
        if case let .failed(message) = phase { message } else { nil }
    }

    var effectiveMaxAttachments: Int {
        Self.clamped(capabilities?.maxAttachments, ceiling: Self.maxAttachments)
    }

    var effectiveMaxAttachmentBytes: Int64 {
        Self.clamped(capabilities?.maxAttachmentBytes, ceiling: Self.maxAttachmentBytes)
    }

    var effectiveMaxTotalAttachmentBytes: Int64 {
        Self.clamped(capabilities?.maxTotalAttachmentBytes, ceiling: Self.maxTotalAttachmentBytes)
    }

    var attachmentByteTotal: Int64 {
        attachments.reduce(into: Int64(0)) { total, attachment in
            let (sum, overflow) = total.addingReportingOverflow(attachment.byteCount)
            total = overflow ? Int64.max : sum
        }
    }

    /// What the title counter shows: the same unit the server limits.
    var titleCharacterCount: Int { title.unicodeScalars.count }

    /// Why the description cannot be sent as written, or nil. The server
    /// refuses C0 controls other than tab, newline and carriage return (and
    /// DEL); they are invisible in the editor, so the sheet says so up front.
    var descriptionProblem: String? {
        Self.containsDisallowedControlCharacters(body)
            ? IssueReportComposerError.descriptionHasControlCharacters.errorDescription
            : nil
    }

    /// True when the draft is complete enough to send: a non-blank title and
    /// description within the server's limits, a machine to file through, and
    /// no submission in flight or already filed.
    var canSubmit: Bool {
        guard !isSubmitting, submittedRecord == nil else { return false }
        return (try? validatedDraft()) != nil
    }

    // MARK: - Attachments

    /// Validates and queues files. Problems are reported through
    /// `attachmentError` (the last one wins) instead of throwing, so one bad
    /// file in a multi-selection never blocks the good ones.
    func addAttachments(_ urls: [URL], ownership: AttachmentSourceOwnership = .userSelected) {
        attachmentError = nil
        appendAttachments(urls, ownership: ownership)
    }

    /// `addAttachments` without clearing `attachmentError`, so one drop or
    /// paste batch that arrives file by file keeps its first rejection.
    func appendAttachments(_ urls: [URL], ownership: AttachmentSourceOwnership = .userSelected) {
        for url in urls {
            let filename = url.lastPathComponent
            guard url.isFileURL else {
                reject(url, ownership: ownership, message: "Attach a local file or image.")
                continue
            }
            guard attachments.count < effectiveMaxAttachments else {
                reject(url, ownership: ownership, message: "Attach up to \(effectiveMaxAttachments) files per report.")
                continue
            }
            guard HerdrAttachmentTypes.isAllowed(url) else {
                reject(url, ownership: ownership, message: "\(filename) isn't a supported file type.")
                continue
            }
            if let problem = Self.filenameProblem(filename) {
                reject(url, ownership: ownership, message: problem)
                continue
            }
            guard !attachments.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
                // Never delete here: the existing entry may own this very file.
                attachmentError = "\(filename) is already attached."
                continue
            }
            do {
                let byteCount = try Self.regularFileSize(at: url)
                guard byteCount > 0 else {
                    reject(url, ownership: ownership, message: "\(filename) is empty and cannot be attached.")
                    continue
                }
                guard byteCount <= effectiveMaxAttachmentBytes else {
                    reject(
                        url,
                        ownership: ownership,
                        message: "\(filename) is larger than the file limit of \(Self.limitLabel(effectiveMaxAttachmentBytes))."
                    )
                    continue
                }
                guard attachmentByteTotal <= effectiveMaxTotalAttachmentBytes - byteCount else {
                    reject(
                        url,
                        ownership: ownership,
                        message: "Attachments can total up to \(Self.limitLabel(effectiveMaxTotalAttachmentBytes)) per report."
                    )
                    continue
                }
                attachments.append(
                    IssueReportAttachment(
                        id: UUID(),
                        url: url,
                        filename: filename,
                        byteCount: byteCount,
                        isImage: HerdrAttachmentTypes.isImage(url),
                        ownership: ownership
                    )
                )
            } catch {
                reject(url, ownership: ownership, message: "Couldn't read \(filename): \(error.localizedDescription)")
            }
        }
    }

    /// Writes pasted or dropped image bytes to a temporary file the composer
    /// owns and queues it. Throws for unusable data or a failed write; policy
    /// rejections (count, total size) surface through `attachmentError`.
    func addImageData(_ data: Data, preferredExtension: String) throws {
        attachmentError = nil
        try appendImageData(data, preferredExtension: preferredExtension)
    }

    /// `addImageData` without clearing `attachmentError`; see `appendAttachments`.
    func appendImageData(_ data: Data, preferredExtension: String) throws {
        guard !isDiscarded else { throw IssueReportComposerError.sheetClosed }
        guard !data.isEmpty else { throw IssueReportComposerError.emptyImage }
        guard Int64(data.count) <= effectiveMaxAttachmentBytes else {
            throw IssueReportComposerError.imageTooLarge(maximumBytes: effectiveMaxAttachmentBytes)
        }
        let directory = try ensureTemporaryDirectory()
        pastedImageCount += 1
        let url = directory.appending(
            path: "pasted-image-\(pastedImageCount).\(Self.imageExtension(preferred: preferredExtension))"
        )
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        appendAttachments([url], ownership: .appTemporary)
    }

    /// Removes one attachment, deleting its file only when the composer wrote it.
    func remove(_ id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: index)
        if attachment.ownership == .appTemporary {
            try? fileManager.removeItem(at: attachment.url)
        }
    }

    /// Deletes every file the composer wrote, along with its folder, and
    /// refuses to write any more. User files are never touched.
    func discardTemporaryFiles() {
        isDiscarded = true
        for attachment in attachments where attachment.ownership == .appTemporary {
            try? fileManager.removeItem(at: attachment.url)
        }
        attachments.removeAll { $0.ownership == .appTemporary }
        if fileManager.fileExists(atPath: temporaryDirectory.path) {
            try? fileManager.removeItem(at: temporaryDirectory)
        }
    }

    /// Launch-time sweep for folders a crash or force-quit left behind.
    /// Mirrors `VoiceRecordingPolicy.removeStaleTemporaryRecordings`.
    static func removeStaleTemporaryDirectories(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = .now
    ) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(temporaryDirectoryPrefix) {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) >= staleTemporaryDirectoryAge
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Request

    /// The environment block shown to the user and sent with the report.
    ///
    /// Deliberately excludes machine names, hostnames, URLs, tokens and
    /// workspace labels: the issue is public.
    static func environmentDetails(
        appVersion: String,
        build: String,
        macOSVersion: String,
        machineRole: String?,
        serverCapabilities: [String]
    ) -> [String: String] {
        let capabilities = serverCapabilities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        var details: [String: String] = [
            "app_version": sanitizedEnvironmentValue(appVersion),
            "app_build": sanitizedEnvironmentValue(build),
            "macos_version": sanitizedEnvironmentValue(macOSVersion),
            "server_capabilities": sanitizedEnvironmentValue(capabilities),
            "client": clientIdentifier,
        ]
        if let role = machineRole?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            details["machine_role"] = sanitizedEnvironmentValue(role)
        }
        return details
    }

    /// The connected companion that should file a report, preferring this
    /// Mac's local machine over the first eligible roster entry.
    static func defaultMachineID(
        machines: [HerdrMachine],
        isConnected: (String) -> Bool,
        canControl: (String) -> Bool
    ) -> String? {
        let eligible = machines.filter { machine in
            isConnected(machine.id) && canControl(machine.id)
        }
        return eligible.first(where: { $0.role == "local" })?.id ?? eligible.first?.id
    }

    /// Builds the wire payload synchronously: the title folded to one line,
    /// the body verbatim except for trailing newlines, and every attachment
    /// read, stripped of photo metadata and base64-encoded with a MIME type
    /// inferred from its extension. `submit` does the same work off the main
    /// actor; this entry point exists for tests and small drafts.
    func makeRequest(environment: [String: String]) throws -> IssueReportRequest {
        let draft = try validatedDraft()
        let bodies = try Self.attachmentBodies(for: attachments, maximumBytes: effectiveMaxAttachmentBytes)
        return draft.request(attachments: bodies, environment: Self.boundedEnvironment(environment))
    }

    /// Validates the draft, reads and encodes the attachments off the main
    /// actor, and hands the request to `send`, tracking the outcome in
    /// `phase`. Errors of any kind become `.failed` with their description; a
    /// dropped connection gets `ambiguousOutcomeMessage` because the issue may
    /// already exist.
    func submit(
        environment: [String: String],
        using send: @MainActor (IssueReportRequest, String) async throws -> IssueReportRecord
    ) async {
        guard canSubmit else { return }
        let draft: ValidatedDraft
        do {
            draft = try validatedDraft()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .submitting
        let queued = attachments
        let maximumBytes = effectiveMaxAttachmentBytes
        let bodies: [IssueReportAttachmentBody]
        do {
            // Up to 40 MiB of file I/O plus base64 and image re-encoding: never
            // on the main thread while the sheet shows "Filing…".
            bodies = try await Task.detached(priority: .userInitiated) {
                try Self.attachmentBodies(for: queued, maximumBytes: maximumBytes)
            }.value
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let request = draft.request(attachments: bodies, environment: Self.boundedEnvironment(environment))
        do {
            let record = try await send(request, machineID)
            phase = .submitted(record)
            // This id now names a filed issue; the next report must not
            // replay it. A failure keeps the id for "Try again".
            clientReportId = Self.makeClientReportId()
        } catch {
            phase = .failed(Self.failureMessage(for: error))
        }
    }

    /// MIME type for a filename, or `application/octet-stream` when the system
    /// has no registered type for its extension.
    nonisolated static func contentType(forFilename filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mimeType = type.preferredMIMEType else { return fallbackContentType }
        return mimeType
    }

    /// The message shown for a failed submission. Timeouts and lost
    /// connections are ambiguous — the server keeps filing after the client
    /// gives up — so they warn before "Try again" instead of inviting it.
    static func failureMessage(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cancelled:
                return ambiguousOutcomeMessage
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// Why `filename` would be refused by the companion server, or nil.
    /// Mirrors `agent_runs._sanitize_attachment_filename`; the extension is
    /// checked separately by `HerdrAttachmentTypes`.
    static func filenameProblem(_ filename: String) -> String? {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            return "\(filename) doesn't have a usable file name. Rename it and attach it again."
        }
        let forbidden = name.unicodeScalars.contains { scalar in
            scalar == "\\" || scalar == "/" || scalar.value == 0 || CharacterSet.newlines.contains(scalar)
        }
        if forbidden {
            return "\(filename) has characters in its name that can't be uploaded (such as a backslash). Rename it and attach it again."
        }
        if name.unicodeScalars.count > maxFilenameCharacters || name.utf16.count > maxFilenameUTF16Units {
            return "\(filename) has a name longer than \(maxFilenameCharacters) characters. Rename it and attach it again."
        }
        return nil
    }

    /// Titles are one line on GitHub and may not contain control characters:
    /// newlines, tabs and other C0/DEL scalars become spaces.
    static func normalizedTitle(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || CharacterSet.newlines.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server's body rule: any scalar below U+0020 other than tab, newline
    /// and carriage return, or U+007F, is refused.
    static func containsDisallowedControlCharacters(_ body: String) -> Bool {
        body.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r") || scalar.value == 0x7F
        }
    }

    /// Re-encodes a photo through ImageIO so Exif, GPS and XMP blocks are
    /// dropped while pixels and orientation survive. Returns nil for formats
    /// that pass through unchanged and for data ImageIO cannot decode (which
    /// then also holds no metadata ImageIO would read).
    nonisolated static func strippingImageMetadata(_ data: Data, filename: String) -> Data? {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard metadataBearingImageExtensions.contains(ext),
              let type = UTType(filenameExtension: ext),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let image: CGImage?
        if orientation == 1 || width <= 0 || height <= 0 {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            // Bake the Exif orientation into the pixels: the block that held it
            // is about to go.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var destinationProperties: [CFString: Any] = [:]
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif) {
            destinationProperties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    // MARK: - Helpers

    /// The parts of a draft that survive validation, ready to pair with the
    /// encoded attachments on whichever actor read them.
    private struct ValidatedDraft: Sendable {
        let kind: IssueReportKind
        let title: String
        let body: String
        let autofix: Bool
        let clientReportId: String

        func request(attachments: [IssueReportAttachmentBody], environment: [String: String]) -> IssueReportRequest {
            IssueReportRequest(
                kind: kind,
                title: title,
                body: body,
                autofix: autofix,
                environment: environment,
                attachments: attachments,
                clientReportId: clientReportId
            )
        }
    }

    private func validatedDraft() throws -> ValidatedDraft {
        guard !machineID.isEmpty else { throw IssueReportComposerError.noMachineSelected }
        let normalizedTitle = Self.normalizedTitle(title)
        guard !normalizedTitle.isEmpty else { throw IssueReportComposerError.missingTitle }
        guard normalizedTitle.unicodeScalars.count <= Self.maxTitleCharacters else {
            throw IssueReportComposerError.titleTooLong(maximum: Self.maxTitleCharacters)
        }
        let verbatimBody = Self.trimmingTrailingNewlines(body)
        guard !verbatimBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IssueReportComposerError.missingDescription
        }
        guard verbatimBody.unicodeScalars.count <= Self.maxBodyCharacters else {
            throw IssueReportComposerError.descriptionTooLong(maximum: Self.maxBodyCharacters)
        }
        guard !Self.containsDisallowedControlCharacters(verbatimBody) else {
            throw IssueReportComposerError.descriptionHasControlCharacters
        }
        return ValidatedDraft(
            kind: kind,
            title: normalizedTitle,
            body: verbatimBody,
            autofix: autofix,
            clientReportId: clientReportId
        )
    }

    private func reject(_ url: URL, ownership: AttachmentSourceOwnership, message: String) {
        attachmentError = message
        if ownership == .appTemporary {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Drops queued files that stopped fitting after the server lowered a
    /// limit, keeping the earliest ones, and says which ones went.
    private func enforceLimits() {
        var kept: [IssueReportAttachment] = []
        var total: Int64 = 0
        var dropped: [IssueReportAttachment] = []
        for attachment in attachments {
            if kept.count >= effectiveMaxAttachments
                || attachment.byteCount > effectiveMaxAttachmentBytes
                || total > effectiveMaxTotalAttachmentBytes - attachment.byteCount {
                dropped.append(attachment)
            } else {
                kept.append(attachment)
                total += attachment.byteCount
            }
        }
        guard !dropped.isEmpty else { return }
        for attachment in dropped where attachment.ownership == .appTemporary {
            try? fileManager.removeItem(at: attachment.url)
        }
        attachments = kept
        let names = dropped.map(\.filename).joined(separator: ", ")
        attachmentError = "\(names) no longer fit\(dropped.count == 1 ? "s" : "") this machine's report limits "
            + "(up to \(effectiveMaxAttachments) files, \(Self.limitLabel(effectiveMaxAttachmentBytes)) each, "
            + "\(Self.limitLabel(effectiveMaxTotalAttachmentBytes)) in total) and \(dropped.count == 1 ? "was" : "were") removed."
    }

    private func ensureTemporaryDirectory() throws -> URL {
        if !fileManager.fileExists(atPath: temporaryDirectory.path) {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return temporaryDirectory
    }

    nonisolated private static func regularFileSize(at url: URL) throws -> Int64 {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw AttachmentPolicyError.unreadableFileSize(filename: url.lastPathComponent)
        }
        return Int64(size)
    }

    nonisolated private static func attachmentBodies(
        for attachments: [IssueReportAttachment],
        maximumBytes: Int64
    ) throws -> [IssueReportAttachmentBody] {
        try attachments.map { try attachmentBody(for: $0, maximumBytes: maximumBytes) }
    }

    nonisolated private static func attachmentBody(
        for attachment: IssueReportAttachment,
        maximumBytes: Int64
    ) throws -> IssueReportAttachmentBody {
        let url = attachment.url
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw IssueReportComposerError.attachmentUnreadable(filename: attachment.filename)
        }
        guard !data.isEmpty, Int64(data.count) <= maximumBytes else {
            throw IssueReportComposerError.attachmentChanged(filename: attachment.filename)
        }
        if attachment.isImage, let stripped = strippingImageMetadata(data, filename: attachment.filename) {
            guard Int64(stripped.count) <= maximumBytes else {
                throw IssueReportComposerError.attachmentTooLargeAfterProcessing(
                    filename: attachment.filename,
                    maximumBytes: maximumBytes
                )
            }
            data = stripped
        }
        return IssueReportAttachmentBody(
            filename: attachment.filename,
            contentType: contentType(forFilename: attachment.filename),
            dataBase64: data.base64EncodedString()
        )
    }

    private static func boundedEnvironment(_ environment: [String: String]) -> [String: String] {
        var bounded: [String: String] = [:]
        for key in environment.keys.sorted() {
            guard bounded.count < maxEnvironmentEntries else { break }
            let cleanKey = String(sanitizedEnvironmentValue(key).prefix(maxEnvironmentKeyLength))
            guard !cleanKey.isEmpty else { continue }
            bounded[cleanKey] = sanitizedEnvironmentValue(environment[key] ?? "")
        }
        return bounded
    }

    private static func sanitizedEnvironmentValue(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(scalars).prefix(maxEnvironmentValueLength))
    }

    /// The only edit ever applied to the description: trailing line breaks.
    private static func trimmingTrailingNewlines(_ body: String) -> String {
        var trimmed = Substring(body)
        while let last = trimmed.last, last.isNewline {
            trimmed.removeLast()
        }
        return String(trimmed)
    }

    private static func imageExtension(preferred: String) -> String {
        let ext = preferred.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return HerdrAttachmentTypes.imageExtensions.contains(ext) ? ext : "png"
    }

    private static func clamped<Value: BinaryInteger>(_ value: Value?, ceiling: Value) -> Value {
        guard let value, value > 0 else { return ceiling }
        return min(value, ceiling)
    }

    /// "20 MB" for the usual mebibyte ceilings, an exact byte count otherwise.
    private static func limitLabel(_ bytes: Int64) -> String {
        let mebibyte: Int64 = 1024 * 1024
        if bytes >= mebibyte, bytes % mebibyte == 0 {
            return "\(bytes / mebibyte) MB"
        }
        return bytes.formatted(.byteCount(style: .file))
    }
}
