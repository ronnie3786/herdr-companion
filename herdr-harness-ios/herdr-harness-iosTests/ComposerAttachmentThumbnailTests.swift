import Foundation
import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

@Suite("Composer attachment thumbnails")
struct ComposerAttachmentThumbnailTests {
    @MainActor
    @Test("Synthetic photos are downsampled into a bounded encoded preview")
    func downsamplesPhoto() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 320))
        let original = renderer.image { context in
            UIColor.systemPurple.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
            UIColor.systemGreen.setFill()
            context.cgContext.fill(CGRect(x: 320, y: 0, width: 320, height: 320))
        }
        let originalData = try #require(original.pngData())
        let thumbnailData = try #require(ComposerAttachmentThumbnail.encodedData(from: originalData))
        let thumbnail = try #require(UIImage(data: thumbnailData))
        let boundedDecode = try #require(ComposerAttachmentThumbnail.boundedImage(from: originalData))

        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 96)
        #expect(max(boundedDecode.size.width, boundedDecode.size.height) <= 96)
        #expect(thumbnailData.count <= ComposerAttachmentThumbnail.maximumEncodedBytes)
    }

    @MainActor
    @Test("Ready and failed attachments retain previews after source cleanup")
    func previewSurvivesUploadAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "herdr-composer-thumbnail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "synthetic-photo.png")
        let original = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        try #require(original.pngData()).write(to: source)
        let preview = try #require(ComposerAttachmentThumbnail.encodedData(at: source))

        var ready = attachment(source: source, status: .uploading, thumbnailData: preview)
        ready.status = .uploaded
        ready.uploaded = uploaded(path: "/synthetic/photo.png")
        ready.removeSourceFileIfOwned()

        var failed = attachment(
            source: directory.appending(path: "failed-photo.png"),
            status: .failed,
            thumbnailData: preview
        )
        failed.error = "Synthetic upload failure"

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(ready.thumbnailData == preview)
        #expect(failed.thumbnailData == preview)

        let remaining = PromptComposerView.remainingAttachments(
            afterRemoving: [ready.id],
            from: [ready, failed]
        )
        #expect(remaining.map(\.id) == [failed.id])
        #expect(remaining.first?.thumbnailData == preview)
    }

    @MainActor
    @Test("Uploading, ready, and failed chips reserve a visible bounded strip")
    func attachmentStripHasVisibleHeight() throws {
        let preview = try #require(
            ComposerAttachmentThumbnail.encodedData(
                from: UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
                    .image { context in
                        UIColor.systemBlue.setFill()
                        context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
                    }
                    .pngData() ?? Data()
            )
        )
        var ready = attachment(status: .uploaded, thumbnailData: preview)
        ready.uploaded = uploaded(path: "/synthetic/ready.png")
        let attachments = [
            attachment(status: .uploading, thumbnailData: preview),
            ready,
            attachment(status: .failed, thumbnailData: preview),
        ]
        let host = UIHostingController(
            rootView: ComposerAttachmentTray(
                attachments: attachments,
                retry: { _ in },
                remove: { _ in }
            )
            .frame(width: 390)
        )
        host.safeAreaRegions = []
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 200))

        #expect(size.width <= 390)
        #expect(size.height >= 68)
        #expect(size.height <= 104)
    }

    private func attachment(
        source: URL = URL(filePath: "/tmp/synthetic-photo.png"),
        status: TerminalAttachmentStatus,
        thumbnailData: Data
    ) -> TerminalAttachment {
        TerminalAttachment(
            id: UUID(),
            filename: source.lastPathComponent,
            sourceURL: source,
            byteCount: Int64(thumbnailData.count),
            sourceOwnership: .appTemporary,
            status: status,
            uploaded: nil,
            error: status == .failed ? "Synthetic upload failure" : nil,
            thumbnailData: thumbnailData
        )
    }

    private func uploaded(path: String) -> UploadedAttachment {
        UploadedAttachment(
            id: UUID().uuidString,
            filename: "synthetic-photo.png",
            originalFilename: "synthetic-photo.png",
            contentType: "image/png",
            size: 100,
            path: path,
            workspaceID: "synthetic-workspace",
            createdAt: "2030-01-01T00:00:00Z"
        )
    }
}
