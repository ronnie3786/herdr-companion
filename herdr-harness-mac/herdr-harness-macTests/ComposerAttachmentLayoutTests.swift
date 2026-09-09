import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Composer attachment layout")
@MainActor
struct ComposerAttachmentLayoutTests {
    @Test("Attachment tray hugs its chips even with a tall height proposal")
    func trayStaysCompact() async throws {
        for status in [TerminalAttachmentStatus.uploading, .uploaded, .failed] {
            for scale in [HerdrFontScale.medium, .xxLarge] {
                let attachments = (0..<4).map { index in
                    TerminalAttachment(
                        id: UUID(),
                        filename: "Sample screenshot \(index).png",
                        sourceURL: URL(filePath: "/tmp/sample-\(index).png"),
                        byteCount: 1024,
                        sourceOwnership: .userSelected,
                        status: status,
                        uploaded: nil,
                        error: status == .failed ? "Upload failed; try again" : nil
                    )
                }
                var trayHeight: CGFloat = 0
                let hosting = NSHostingView(rootView:
                    ComposerAttachmentTray(attachments: attachments, retry: { _ in }, remove: { _ in })
                        .environment(\.herdrFontScale, scale)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { trayHeight = $0 }
                        .frame(width: 320, height: 600, alignment: .top)
                )
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                defer { window.close() }
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                #expect(trayHeight >= 44)
                #expect(trayHeight < 100, "Attachments should not consume spare composer height")
            }
        }
    }
}
