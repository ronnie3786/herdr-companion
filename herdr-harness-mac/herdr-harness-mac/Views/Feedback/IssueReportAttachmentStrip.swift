import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The attachment row of the report sheet: chips for queued files, the
/// "Add files…" button, drop hint and the last validation error.
struct IssueReportAttachmentStrip: View {
    let composer: IssueReportComposer
    let isDropTargeted: Bool
    let addFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Attachments")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.muted)
                Text("\(composer.attachments.count) of \(composer.effectiveMaxAttachments) · \(composer.attachmentByteTotal.formatted(.byteCount(style: .file)))")
                    .herdrFont(.caption2, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityIdentifier("issue-report-attachment-count")
                Spacer()
                Button("Add files…", systemImage: "paperclip", action: addFiles)
                    .disabled(composer.attachments.count >= composer.effectiveMaxAttachments)
                    .accessibilityIdentifier("issue-report-add-files")
            }

            if composer.attachments.isEmpty {
                Text("Drop screenshots or documents here, or press ⌘V to paste an image.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(composer.attachments) { attachment in
                        IssueReportAttachmentChip(attachment: attachment) {
                            composer.remove(attachment.id)
                        }
                    }
                }
            }

            if let error = composer.attachmentError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-attachment-error")
            }
        }
        .padding(12)
        .background(HerdrTheme.elevated.opacity(isDropTargeted ? 0.95 : 0.6))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(
                    isDropTargeted ? HerdrTheme.accent : HerdrTheme.separator,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [] : [6, 4])
                )
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier("issue-report-attachments")
    }
}

/// One queued file: thumbnail or type glyph, name, size and a remove button.
struct IssueReportAttachmentChip: View {
    let attachment: IssueReportAttachment
    let remove: () -> Void
    @State private var thumbnailImage: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.byteCount.formatted(.byteCount(style: .file)))
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .foregroundStyle(HerdrTheme.muted)
                    .herdrHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
            .accessibilityIdentifier("issue-report-remove-\(attachment.filename)")
        }
        .padding(.leading, 6)
        .padding(.vertical, 6)
        .padding(.trailing, 2)
        .background(HerdrTheme.surface, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier("issue-report-attachment-\(attachment.filename)")
        .task(id: attachment.id) {
            guard attachment.isImage else { return }
            let url = attachment.url
            guard let cgImage = await (Task.detached(priority: .utility) {
                Self.loadThumbnail(url: url)
            }.value) else { return }
            thumbnailImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnailImage {
            Image(nsImage: thumbnailImage)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        } else {
            Image(systemName: attachment.isImage ? "photo" : Self.symbolName(forExtension: URL(fileURLWithPath: attachment.filename).pathExtension))
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .frame(width: 32, height: 32)
                .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        }
    }

    private static func symbolName(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": "doc.richtext"
        case "csv", "tsv": "tablecells"
        case "json", "yaml", "yml", "xml", "toml", "plist": "curlybraces"
        case "log": "text.alignleft"
        default: "doc.text"
        }
    }

    nonisolated private static func loadThumbnail(url: URL) -> CGImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Drop and paste import

extension IssueReportComposer {
    /// A drop or paste item after its provider loaded it.
    enum ImportedItem: Equatable, Sendable {
        case file(URL)
        case image(Data, extension: String)
    }

    /// Files and images dropped on the sheet or pasted with ⌘V.
    ///
    /// Same shape as `HerdrHudSession.acceptAttachmentDrop`: Finder files are
    /// queued by URL, image data is written to a composer-owned temporary
    /// file. Returns whether any provider could be handled; the import itself
    /// runs in a task because providers load asynchronously.
    @discardableResult
    func importItemProviders(_ providers: [NSItemProvider]) -> Bool {
        let supported = Self.supportedProviders(providers)
        guard !supported.isEmpty else { return false }
        Task { await importProviders(supported) }
        return true
    }

    /// The awaitable core of `importItemProviders`. The whole batch shares one
    /// `attachmentError` reset, so dropping `archive.zip` next to `shot.png`
    /// still reports the zip after the png was queued.
    func importProviders(_ providers: [NSItemProvider]) async {
        let supported = Self.supportedProviders(providers)
        guard !supported.isEmpty, !isDiscarded else { return }
        attachmentError = nil
        var items: [ImportedItem] = []
        for provider in supported.prefix(Self.maxAttachments) {
            do {
                if let item = try await Self.loadItem(from: provider) {
                    items.append(item)
                } else {
                    attachmentError = "Drop a local file or image."
                }
            } catch {
                attachmentError = "Couldn't attach the item: \(error.localizedDescription)"
            }
        }
        // The sheet may have closed while the providers were loading.
        guard !isDiscarded else { return }
        appendAttachments(items.compactMap { if case let .file(url) = $0 { url } else { nil } })
        for case let .image(data, ext) in items {
            do {
                try appendImageData(data, preferredExtension: ext)
            } catch {
                attachmentError = "Couldn't attach the image: \(error.localizedDescription)"
            }
        }
    }

    /// ⌘V with an image-only clipboard, routed here by `IssueReportPasteMonitor`
    /// when a text field owns the paste command. Returns whether the
    /// pasteboard held an image.
    @discardableResult
    func importPasteboardImage(_ pasteboard: NSPasteboard) -> Bool {
        guard !isDiscarded, let (data, type) = Self.pasteboardImage(pasteboard) else { return false }
        let image = Self.attachableImage(from: data, type: type)
        do {
            try addImageData(image.data, preferredExtension: image.extension)
        } catch {
            attachmentError = "Couldn't attach the image: \(error.localizedDescription)"
        }
        return true
    }

    /// GitHub renders PNG, JPEG, GIF and WebP inline; anything else (TIFF from
    /// the clipboard, HEIC from Photos) is re-encoded as PNG so the screenshot
    /// shows up in the issue instead of as a bare download link.
    static func attachableImage(from data: Data, type: UTType) -> (data: Data, extension: String) {
        let inline: [UTType] = [.png, .jpeg, .gif, .webP]
        if let match = inline.first(where: { type.conforms(to: $0) }) {
            return (data, match.preferredFilenameExtension ?? "png")
        }
        if let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return (data, type.preferredFilenameExtension ?? "png")
    }

    private static func supportedProviders(_ providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }

    /// Resolves one provider to a file URL or image bytes; nil when the
    /// provider claimed a file URL that is not a local file.
    private static func loadItem(from provider: NSItemProvider) async throws -> ImportedItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let data = try await loadData(from: provider, type: UTType.fileURL.identifier)
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
            return .file(url)
        }
        guard let type = preferredImageType(for: provider) else { return nil }
        let data = try await loadData(from: provider, type: type.identifier)
        let image = attachableImage(from: data, type: type)
        return .image(image.data, extension: image.extension)
    }

    private static func loadData(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private static func preferredImageType(for provider: NSItemProvider) -> UTType? {
        let registered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        return registered.first { $0.conforms(to: .png) }
            ?? registered.first { $0.conforms(to: .jpeg) }
            ?? registered.first { $0.conforms(to: .image) }
    }

    /// The first image representation on the pasteboard, preferring formats
    /// GitHub renders inline, then anything `NSImage` can read.
    private static func pasteboardImage(_ pasteboard: NSPasteboard) -> (Data, UTType)? {
        for type in [UTType.png, .jpeg, .tiff, .heic] {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)), !data.isEmpty {
                return (data, type)
            }
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let tiff = image.tiffRepresentation, !tiff.isEmpty {
            return (tiff, .tiff)
        }
        return nil
    }
}
