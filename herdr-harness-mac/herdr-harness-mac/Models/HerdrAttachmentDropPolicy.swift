import AppKit
import UniformTypeIdentifiers

/// Drop rules for the HUD, kept pure so classification is testable without a
/// live drag and so the AppKit drop target and the `NSItemProvider` path agree
/// on what is acceptable.
enum HerdrAttachmentDropPolicy {
    /// Types that make the HUD a drop destination. The promise metadata types are
    /// what an `NSFilePromiseProvider` writes, which is how the system screenshot
    /// preview and other apps hand over a file that does not exist yet. The
    /// concrete image UTIs keep raw image drags addressed to the HUD even when
    /// AppKit does not add its own TIFF conversion.
    static let registeredTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .tiff,
        .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
        NSPasteboard.PasteboardType(UTType.image.identifier),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("NSFilesPromisePboardType"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
    ]

    static let promiseDirectoryName = "HerdrDroppedPromises"

    /// A drag is acceptable when it carries a file, a file promise, or image
    /// data. Nothing else may highlight the HUD as a target.
    static func accepts(pasteboardTypes: [NSPasteboard.PasteboardType]) -> Bool {
        guard !pasteboardTypes.isEmpty else { return false }
        for type in pasteboardTypes {
            if type == .fileURL || type == .tiff || type == .png { return true }
            if isFilePromiseType(type) { return true }
            if let utType = UTType(type.rawValue), utType.conforms(to: .image) { return true }
        }
        return false
    }

    static func isFilePromiseType(_ type: NSPasteboard.PasteboardType) -> Bool {
        type.rawValue == "com.apple.NSFilePromiseItemMetaData"
            || type.rawValue == "NSFilesPromisePboardType"
            || type.rawValue.hasPrefix("com.apple.pasteboard.promised-file")
    }

    /// Whether an `NSItemProvider` can become one HUD attachment. Providers
    /// created by SwiftUI for a Finder image drag may expose no file URL at all,
    /// only an image representation, so conformance to `public.image` counts.
    static func providerCarriesAttachment(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || !imageTypeCandidates(for: provider).isEmpty
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Every registered representation that conforms to `public.image`, in the
    /// provider's own order (higher fidelity first). A provider can advertise a
    /// representation whose loader is missing, so callers try each one.
    static func imageTypeCandidates(for provider: NSItemProvider) -> [String] {
        provider.registeredTypeIdentifiers.filter {
            UTType($0)?.conforms(to: .image) == true
        }
    }

    /// File promises on a dragging pasteboard. `NSFilePromiseReceiver` instances
    /// are only valid while the drag is live, so this must be called from the
    /// drop callback.
    static func filePromiseReceivers(in pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
    }

    /// Exactly one preferred representation for a single dropped pasteboard
    /// item. One item is one dropped thing: resolving per item keeps two image
    /// items from collapsing into one attachment and keeps an inline image
    /// beside a file item from being ignored.
    enum ItemPayload: Equatable {
        case file(URL)
        case image(data: Data, type: UTType)
    }

    /// One payload per pasteboard item, in item order. Within an item a real
    /// file URL wins over image pixels, and the image branch picks a single
    /// representation, so a dropped item never attaches twice.
    static func itemPayloads(in pasteboard: NSPasteboard) -> [ItemPayload] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            if let url = localFileURL(in: item) { return .file(url) }
            if let image = imagePayload(in: item) {
                return .image(data: image.data, type: image.type)
            }
            return nil
        }
    }

    /// Real files on the dragging pasteboard. `NSURL` readers can also decode a
    /// plain web URL — a browser image drag carries the image's source URL next
    /// to its pixels — so only file URLs are returned and the caller can fall
    /// through to the image data instead of trying to read a URL as a file.
    static func localFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { localFileURL(in: $0) }
    }

    /// A real file URL on one pasteboard item. A browser drag carries a plain
    /// web URL beside its pixels; only `file://` URLs count, so the web URL
    /// cannot shadow the image data.
    static func localFileURL(in item: NSPasteboardItem) -> URL? {
        for type in [NSPasteboard.PasteboardType.fileURL, .URL] {
            guard let data = item.data(forType: type),
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.isFileURL
            else { continue }
            return url
        }
        return nil
    }

    /// The first inline image payload on a dragging pasteboard, per item.
    static func imagePayload(in pasteboard: NSPasteboard) -> (data: Data, type: UTType)? {
        for item in pasteboard.pasteboardItems ?? [] {
            if let payload = imagePayload(in: item) { return payload }
        }
        return nil
    }

    /// One item's preferred image representation. A declared PNG representation
    /// wins because it is lossless; otherwise the item's own declared image
    /// types are used in order, so an original JPEG is not replaced by one of
    /// AppKit's synthesized conversions. The TIFF conversion is the last resort.
    static func imagePayload(in item: NSPasteboardItem) -> (data: Data, type: UTType)? {
        let declared = item.types.compactMap { type -> (pasteboardType: NSPasteboard.PasteboardType, utType: UTType)? in
            guard let utType = UTType(type.rawValue), utType.conforms(to: .image) else { return nil }
            return (type, utType)
        }
        if let png = declared.first(where: { $0.utType.conforms(to: .png) }),
           let data = item.data(forType: png.pasteboardType) {
            return (data, .png)
        }
        for candidate in declared {
            if let data = item.data(forType: candidate.pasteboardType) {
                return (data, candidate.utType)
            }
        }
        if let data = item.data(forType: .tiff) {
            return (data, .tiff)
        }
        return nil
    }

    /// Where promised files are staged before validation. The attachment
    /// import path copies them into the durable attachment store, so this is
    /// only a staging area.
    static func promiseDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(promiseDirectoryName, isDirectory: true)
    }
}
