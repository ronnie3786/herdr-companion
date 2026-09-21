import AppKit

/// Keeps the SwiftUI and AppKit drop paths aligned, including browser links.
enum PRReviewContextDropPolicy {
    static let registeredTypes = HerdrAttachmentDropPolicy.registeredTypes + [.URL, .string]

    static func accepts(pasteboardTypes: [NSPasteboard.PasteboardType]) -> Bool {
        HerdrAttachmentDropPolicy.accepts(pasteboardTypes: pasteboardTypes)
            || pasteboardTypes.contains(.URL)
    }
}

enum PRReviewContextDocumentTypes {
    static let allowedExtensions: Set<String> = [
        "md", "markdown", "html", "htm", "pdf", "txt", "json",
        "mp3", "m4a", "wav", "mov", "mp4", "m4v", "webm",
    ]
}
