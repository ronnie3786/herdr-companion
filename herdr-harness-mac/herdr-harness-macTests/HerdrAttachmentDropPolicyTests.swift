import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("HUD attachment drop policy")
@MainActor
struct HerdrAttachmentDropPolicyTests {
    @Test("A real file, a file promise, and image data are all acceptable")
    func acceptsFilesPromisesAndImages() {
        #expect(HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [.fileURL]))
        #expect(HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [
            NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
        ]))
        #expect(HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [
            NSPasteboard.PasteboardType("NSFilesPromisePboardType")
        ]))
        // The promise bookkeeping types the system screenshot preview also writes.
        #expect(HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
        ]))
        #expect(HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [.tiff]))
        #expect(HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [.png]))
        // Any image UTI, including dynamic ones from browsers.
        #expect(HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [
            NSPasteboard.PasteboardType("public.jpeg")
        ]))
        #expect(!HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [
            NSPasteboard.PasteboardType("com.apple.finder.node")
        ]))
    }

    @Test("Text, colors, and empty drags never become HUD drop targets")
    func rejectsNonFileDrags() {
        #expect(!HerdrAttachmentDropPolicy.accepts(pasteboardTypes: []))
        #expect(!HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [.string]))
        #expect(!HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [.html]))
        #expect(!HerdrAttachmentDropPolicy.accepts(pasteboardTypes: [.color]))
    }

    @Test("The HUD registers the promise types a screenshot preview drag carries")
    func registersPromiseTypes() {
        let registered = Set(HerdrAttachmentDropPolicy.registeredTypes.map(\.rawValue))
        #expect(registered.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
        #expect(registered.contains(NSPasteboard.PasteboardType.tiff.rawValue))
        #expect(registered.contains("com.apple.NSFilePromiseItemMetaData"))
        #expect(registered.contains("NSFilesPromisePboardType"))
        #expect(registered.contains("com.apple.pasteboard.promised-file-url"))
    }

    @Test("Promised files are staged in a directory the app owns")
    func promiseDirectoryShape() {
        let directory = HerdrAttachmentDropPolicy.promiseDirectory()
        #expect(directory.lastPathComponent == HerdrAttachmentDropPolicy.promiseDirectoryName)
        #expect(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
