import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

/// Full composer renders with real attachment tray presentation. Attachments
/// are inert synthetic values; one tiny temporary source is removed before
/// rendering, and no upload, network, or microphone action is started.
@MainActor
final class PromptComposerAttachmentRenderTests: XCTestCase {
    private let widths: [CGFloat] = [320, 375, 402, 430]
    private let dynamicTypeSizes: [IOSNativeRenderHarness.DynamicTypeFixture] = [
        .defaultSize,
        .accessibility3,
    ]
    private let harness = IOSNativeRenderHarness()

    func testFullPromptComposerAttachmentStripRenderMatrix() async throws {
        let fixture = try IOSMobileV2TestFixture.make(testCase: self)
        let configuration = IOSMobileV2ConfigurationFixture.configuration(
            modelName: "Synthetic Standard",
            thinkingLevel: PiThinkingLevel.high.rawValue
        )
        let audioPlayer = IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: true)
        let syntheticAttachments = attachments
        let readyPhoto = try XCTUnwrap(syntheticAttachments.first { $0.filename == "synthetic-photo.png" })
        let thumbnailData = try XCTUnwrap(readyPhoto.thumbnailData)
        try Data("synthetic source removed before render".utf8).write(to: readyPhoto.sourceURL)
        defer { try? FileManager.default.removeItem(at: readyPhoto.sourceURL) }
        readyPhoto.removeSourceFileIfOwned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: readyPhoto.sourceURL.path))
        XCTAssertEqual(readyPhoto.thumbnailData, thumbnailData)
        XCTAssertLessThanOrEqual(thumbnailData.count, 64 * 1_024)
        XCTAssertNotNil(UIImage(data: thumbnailData))

        let directory = try renderDirectory()
        print("HERDR_IOS_PROMPT_COMPOSER_RENDER_DIR=\(directory.path)")

        for (widthIndex, width) in widths.enumerated() {
            for dynamicType in dynamicTypeSizes {
                let orderedAttachments = rotatedAttachments(
                    syntheticAttachments,
                    startingAt: widthIndex % syntheticAttachments.count
                )
                let leadingAttachment = orderedAttachments[0]
                let surface = FullPromptComposerRenderSurface(
                    model: fixture.model,
                    pane: fixture.pane,
                    workspace: fixture.workspace,
                    configuration: configuration,
                    audioPlayer: audioPlayer,
                    attachments: orderedAttachments
                )
                let render = await harness.render(
                    surface,
                    width: width,
                    dynamicType: dynamicType
                )
                let artifactName = "prompt-attachments-\(Int(width))-\(dynamicType.name)-\(leadingAttachment.status.rawValue)"
                try save(render: render, name: artifactName, directory: directory)
                try saveGeometryDiagnostics(
                    render: render,
                    name: artifactName,
                    directory: directory
                )

                let context = "\(Int(width))pt, \(dynamicType.name), leading \(leadingAttachment.status.rawValue)"
                XCTAssertTrue(render.drewHierarchy, "UIKit should draw the full composer: \(context)")
                XCTAssertGreaterThan(render.fittingSize.height, 0, "Full composer must have visible height: \(context)")
                XCTAssertLessThanOrEqual(render.fittingSize.width, width, "Full composer overflow: \(context)")
                XCTAssertEqual(render.bounds.width, width)

                let composer = try XCTUnwrap(
                    render.element(identifier: "prompt-composer"),
                    "Missing full composer input: \(context)\n\(render.measurementDiagnostics)"
                )
                assertVerticallyContained(composer.frame, in: render.bounds, name: "composer input", context: context)
                XCTAssertGreaterThanOrEqual(composer.frame.height, 48, "Composer input target: \(context)")

                let attachmentTray = try XCTUnwrap(
                    render.element(identifier: "composer-attachments"),
                    "Missing full attachment tray: \(context)\n\(render.measurementDiagnostics)"
                )
                XCTAssertGreaterThanOrEqual(attachmentTray.frame.height, 68, "Attachment tray collapsed: \(context)")
                assertVerticallyContained(
                    attachmentTray.frame,
                    in: render.bounds,
                    name: "attachment tray",
                    context: context
                )

                for attachment in syntheticAttachments {
                    XCTAssertNotNil(
                        render.element(label: "Remove \(attachment.displayName)"),
                        "Every synthetic attachment must remain in the real tray: \(attachment.displayName), \(context)"
                    )
                }
                XCTAssertNotNil(render.element(label: "Ready"), "Uploaded attachment state missing: \(context)")
                XCTAssertNotNil(render.element(label: "Uploading"), "Uploading attachment state missing: \(context)")
                XCTAssertNotNil(
                    render.element(label: "Retry synthetic-failed.pdf"),
                    "Failed attachment retry state missing: \(context)"
                )

                let leadingRemove = try XCTUnwrap(
                    render.element(label: "Remove \(leadingAttachment.displayName)"),
                    "Leading attachment is absent: \(context)"
                )
                let visibleLeadingFrame = leadingRemove.frame.intersection(render.bounds)
                XCTAssertGreaterThan(visibleLeadingFrame.width, 0, "Leading attachment is clipped horizontally: \(context)")
                XCTAssertGreaterThanOrEqual(visibleLeadingFrame.height, 44, "Attachment strip has no usable visible height: \(context)")
                assertVerticallyContained(
                    leadingRemove.frame,
                    in: render.bounds,
                    name: "leading attachment",
                    context: context
                )

                let visibleAttachmentFrames = render.measurements
                    .filter { snapshot in
                        guard let label = snapshot.label else { return false }
                        return (label.hasPrefix("Remove ")
                            || label.hasPrefix("Retry ")
                            || label == "Ready"
                            || label == "Uploading")
                            && snapshot.frame.intersects(render.bounds)
                    }
                    .map(\.frame)
                let visibleStripFrame = visibleAttachmentFrames.reduce(CGRect.null) { $0.union($1) }
                XCTAssertFalse(visibleStripFrame.isNull, "Attachment strip must render visible controls: \(context)")
                XCTAssertGreaterThanOrEqual(visibleStripFrame.height, 44, "Attachment strip collapsed: \(context)")
                assertVerticallyContained(visibleStripFrame, in: render.bounds, name: "attachment strip", context: context)

            }
        }
    }

    private var attachments: [TerminalAttachment] {
        [
            TerminalAttachment(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
                filename: "synthetic-photo.png",
                sourceURL: FileManager.default.temporaryDirectory
                    .appending(path: "herdr-removed-\(UUID().uuidString)-photo-source.png"),
                byteCount: 1_024,
                sourceOwnership: .appTemporary,
                status: .uploaded,
                uploaded: UploadedAttachment(
                    id: "synthetic-photo",
                    filename: "synthetic-photo.png",
                    originalFilename: "synthetic-photo.png",
                    contentType: "image/png",
                    size: 1_024,
                    path: "/synthetic/attachments/synthetic-photo.png",
                    workspaceID: "synthetic-workspace",
                    createdAt: "2030-01-01T00:00:00Z"
                ),
                error: nil,
                thumbnailData: syntheticThumbnailData
            ),
            TerminalAttachment(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
                filename: "synthetic-upload.txt",
                sourceURL: URL(fileURLWithPath: "/tmp/herdr-synthetic-upload.txt"),
                byteCount: 512,
                sourceOwnership: .userSelected,
                status: .uploading,
                uploaded: nil,
                error: nil
            ),
            TerminalAttachment(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
                filename: "synthetic-failed.pdf",
                sourceURL: URL(fileURLWithPath: "/tmp/herdr-synthetic-failed.pdf"),
                byteCount: 2_048,
                sourceOwnership: .userSelected,
                status: .failed,
                uploaded: nil,
                error: "Synthetic upload failure"
            ),
        ]
    }

    private var syntheticThumbnailData: Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: 16, height: 16),
            format: format
        ).pngData { context in
            UIColor(red: 0.62, green: 0.73, blue: 0.68, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            UIColor(red: 0.73, green: 0.65, blue: 0.88, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        }
    }

    private func rotatedAttachments(
        _ values: [TerminalAttachment],
        startingAt index: Int
    ) -> [TerminalAttachment] {
        Array(values[index...] + values[..<index])
    }

    private func assertVerticallyContained(
        _ frame: CGRect,
        in bounds: CGRect,
        name: String,
        context: String
    ) {
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 0.5, "\(name) clips top: \(context)")
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.5, "\(name) clips bottom: \(context)")
    }

    private func save(
        render: IOSNativeRenderHarness.HostedRender,
        name: String,
        directory: URL
    ) throws {
        let filename = "\(name).png"
        let output = directory.appending(path: filename)
        let png = try XCTUnwrap(render.image.pngData())
        try png.write(to: output, options: .atomic)
        let attachment = XCTAttachment(image: render.image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func saveGeometryDiagnostics(
        render: IOSNativeRenderHarness.HostedRender,
        name: String,
        directory: URL
    ) throws {
        let filename = "\(name)-geometry.txt"
        let data = Data(render.measurementDiagnostics.utf8)
        try data.write(to: directory.appending(path: filename), options: .atomic)
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func renderDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["HERDR_IOS_RENDER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
            .appending(path: "herdr-ios-prompt-composer-renders", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private struct FullPromptComposerRenderSurface: View {
    let model: HerdrAppModel
    let pane: HerdrPane
    let workspace: HerdrWorkspace
    let configuration: PiPromptComposerConfiguration
    let audioPlayer: ResponseAudioPlayer
    @State private var draft = "Synthetic attachment review"
    @State private var attachments: [TerminalAttachment]

    init(
        model: HerdrAppModel,
        pane: HerdrPane,
        workspace: HerdrWorkspace,
        configuration: PiPromptComposerConfiguration,
        audioPlayer: ResponseAudioPlayer,
        attachments: [TerminalAttachment]
    ) {
        self.model = model
        self.pane = pane
        self.workspace = workspace
        self.configuration = configuration
        self.audioPlayer = audioPlayer
        _attachments = State(initialValue: attachments)
    }

    var body: some View {
        PromptComposerView(
            model: model,
            pane: pane,
            workspace: workspace,
            draft: $draft,
            attachments: $attachments,
            focusRequest: 0,
            piConfiguration: configuration,
            responseAudioPlayer: audioPlayer,
            activateResponseAudio: { _ in }
        )
        .padding(12)
        .background(HerdrTheme.graphite)
    }
}
