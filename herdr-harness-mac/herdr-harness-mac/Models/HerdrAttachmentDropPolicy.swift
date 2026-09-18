import AppKit
import UniformTypeIdentifiers

/// Drop rules for the HUD, kept pure so classification is testable without a
/// live drag and so the AppKit drop target and the `NSItemProvider` path agree
/// on what is acceptable.
enum HerdrAttachmentDropPolicy {
    /// Types that make the HUD a drop destination. The promise metadata types are
    /// what an `NSFilePromiseProvider` writes, which is how the system screenshot
    /// preview and other apps hand over a file that does not exist yet.
    static let registeredTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .tiff,
        .png,
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

    /// Where a promised file is materialized before validation. The attachment
    /// import path copies it into the durable attachment store, so this is only
    /// a staging area.
    static func promiseDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(promiseDirectoryName, isDirectory: true)
    }
}
