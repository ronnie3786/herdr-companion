import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
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

    @Test("The HUD registers the file, image, and promise types a drag can carry")
    func registersSupportedTypes() {
        let registered = Set(HerdrAttachmentDropPolicy.registeredTypes.map(\.rawValue))
        #expect(registered.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
        #expect(registered.contains(NSPasteboard.PasteboardType.tiff.rawValue))
        #expect(registered.contains(NSPasteboard.PasteboardType.png.rawValue))
        #expect(registered.contains(UTType.jpeg.identifier))
        #expect(registered.contains(UTType.gif.identifier))
        #expect(registered.contains(UTType.heic.identifier))
        #expect(registered.contains(UTType.image.identifier))
        #expect(registered.contains("com.apple.NSFilePromiseItemMetaData"))
        #expect(registered.contains("NSFilesPromisePboardType"))
        #expect(registered.contains("com.apple.pasteboard.promised-file-url"))
    }

    @Test("Only real files survive the pasteboard URL read")
    func localFileURLsFilterWebURLs() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-policy.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let pasteboard = makePasteboard {
            $0.setData(Data("https://example.invalid/photo.png".utf8), forType: NSPasteboard.PasteboardType("public.url"))
            $0.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        }
        #expect(HerdrAttachmentDropPolicy.localFileURLs(in: pasteboard).isEmpty)

        let filePasteboard = makePasteboard { $0.writeObjects([source as NSURL]) }
        #expect(HerdrAttachmentDropPolicy.localFileURLs(in: filePasteboard) == [source])
    }

    @Test("An image payload prefers PNG, then TIFF, then any declared image type")
    func imagePayloadPreference() throws {
        let pngBytes = HerdrDropImageFixtures.makePNG()
        let tiffBytes = HerdrDropImageFixtures.makeTIFF()

        let pngPasteboard = makePasteboard {
            $0.setData(tiffBytes, forType: .tiff)
            $0.setData(pngBytes, forType: .png)
        }
        let pngPayload = try #require(HerdrAttachmentDropPolicy.imagePayload(in: pngPasteboard))
        #expect(pngPayload.type == .png)
        #expect(pngPayload.data == pngBytes)

        let tiffPasteboard = makePasteboard { $0.setData(tiffBytes, forType: .tiff) }
        let tiffPayload = try #require(HerdrAttachmentDropPolicy.imagePayload(in: tiffPasteboard))
        #expect(tiffPayload.type == .tiff)
        #expect(tiffPayload.data == tiffBytes)

        let jpegPasteboard = makePasteboard {
            $0.setData(HerdrDropImageFixtures.makeJPEG(), forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        }
        let jpegPayload = try #require(HerdrAttachmentDropPolicy.imagePayload(in: jpegPasteboard))
        #expect(jpegPayload.type.conforms(to: .image))
        #expect(!jpegPayload.data.isEmpty)
    }

    @Test("Payloads resolve one preferred representation per pasteboard item")
    func itemPayloadsResolvePerItem() throws {
        let pngBytes = HerdrDropImageFixtures.makePNG()
        let jpegBytes = HerdrDropImageFixtures.makeJPEG()

        // One item advertising TIFF and PNG still yields a single PNG payload;
        // a second item keeps its own bytes instead of collapsing into the
        // first matching pasteboard representation.
        let imageItems = makePasteboard {
            let first = NSPasteboardItem()
            first.setData(HerdrDropImageFixtures.makeTIFF(), forType: .tiff)
            first.setData(pngBytes, forType: .png)
            let second = NSPasteboardItem()
            second.setData(jpegBytes, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            $0.writeObjects([first, second])
        }
        #expect(HerdrAttachmentDropPolicy.itemPayloads(in: imageItems) == [
            .image(data: pngBytes, type: .png),
            .image(data: jpegBytes, type: .jpeg),
        ])

        // A browser drag's web URL shares the item with the pixels; the web
        // URL is not a file and must not shadow the image data.
        let browser = makePasteboard {
            $0.setData(Data("https://example.invalid/photo.png".utf8), forType: NSPasteboard.PasteboardType("public.url"))
            $0.setData(pngBytes, forType: .png)
        }
        #expect(HerdrAttachmentDropPolicy.itemPayloads(in: browser) == [
            .image(data: pngBytes, type: .png),
        ])

        // A real file URL inside one item wins over that item's image pixels,
        // while a separate image item is still resolved.
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-mixed.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let mixed = makePasteboard {
            let fileItem = NSPasteboardItem()
            fileItem.setData(Data(source.absoluteString.utf8), forType: .fileURL)
            fileItem.setData(pngBytes, forType: .png)
            let imageItem = NSPasteboardItem()
            imageItem.setData(jpegBytes, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            $0.writeObjects([fileItem, imageItem])
        }
        #expect(HerdrAttachmentDropPolicy.itemPayloads(in: mixed) == [
            .file(source),
            .image(data: jpegBytes, type: .jpeg),
        ])
    }

    @Test("Providers advertise their attachment capability and image candidates in order")
    func providerClassification() async throws {
        let fileProvider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/example.pdf") as NSURL)
        #expect(HerdrAttachmentDropPolicy.providerCarriesAttachment(fileProvider))
        #expect(HerdrAttachmentDropPolicy.imageTypeCandidates(for: fileProvider).isEmpty)

        let imageProvider = NSItemProvider()
        imageProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Data([0x89]), nil)
            return nil
        }
        imageProvider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in
            completion(Data([0x49]), nil)
            return nil
        }
        #expect(HerdrAttachmentDropPolicy.providerCarriesAttachment(imageProvider))
        #expect(HerdrAttachmentDropPolicy.imageTypeCandidates(for: imageProvider) == [
            UTType.png.identifier,
            UTType.tiff.identifier,
        ])

        #expect(!HerdrAttachmentDropPolicy.providerCarriesAttachment(NSItemProvider(object: "text" as NSString)))
    }

    @Test("A synthetic pasteboard without a live drag exposes no promised receivers")
    func promiseReceiversRequireALiveDrag() {
        let pasteboard = makePasteboard {
            $0.setData(Data([0x01]), forType: NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"))
        }
        #expect(HerdrAttachmentDropPolicy.filePromiseReceivers(in: pasteboard).isEmpty)
    }

    @Test("Promised files are staged in a directory the app owns")
    func promiseDirectoryShape() {
        let directory = HerdrAttachmentDropPolicy.promiseDirectory()
        #expect(directory.lastPathComponent == HerdrAttachmentDropPolicy.promiseDirectoryName)
        #expect(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    private func makePasteboard(_ configure: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HerdrAttachmentDropPolicyTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        configure(pasteboard)
        return pasteboard
    }
}
