import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Offscreen renders of the skim in First Mate chat (
/// both appearances, the largest text size), its pending and Full reply states,
/// the HUD, and the cards a phrase opens. PNGs land in the render directory.
@Suite("First Mate skim renders", .serialized)
@MainActor
struct FirstMateSkimRenderTests {
    private static func message(_ json: String = FirstMateSkimFixtures.raceJSON) throws -> FirstMateMessage {
        try FirstMateSkimFixtures.message(json)
    }

    private func chatRow(_ message: FirstMateMessage, scheme: ColorScheme, state: SkimDisplayState? = nil) -> some View {
        FirstMateMessageView(message: message)
            .environment(\.skimDisplayState, state)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, 16)
            .background(FirstMatePalette(scheme: scheme).background)
            .environment(\.colorScheme, scheme)
    }

    @Test("A skim replaces a long reply at chat width, in both appearances",
          arguments: [ColorScheme.dark, .light])
    func chatWidth(scheme: ColorScheme) async throws {
        let message = try Self.message()
        let name = scheme == .dark ? "dark" : "light"
        let render = try await HerdrRenderHarness.render("first-mate-skim-chat-\(name).png", size: CGSize(width: 760, height: 420)) {
            chatRow(message, scheme: scheme)
        }
        render.expectSubstantial(minimumBytes: 4_096)
        let bitmap = try skimBitmap(of: render)
        let attention = try skimRGB(HerdrTheme.attentionBadge)
        #expect(skimPixelCount(in: bitmap, matching: attention) >= 6, "The next-step dot should be First Mate's attention color")
    }

    @Test("A skim fits the largest text size")
    func largestText() async throws {
        let message = try Self.message(FirstMateSkimFixtures.txnJSON)
        let largest = try await HerdrRenderHarness.render("first-mate-skim-largest-text.png", size: CGSize(width: 760, height: 620)) {
            chatRow(message, scheme: .dark)
                .environment(\.herdrFontScale, .xxxLarge)
        }
        largest.expectSubstantial(minimumBytes: 4_096)
    }

    @Test("A pending skim shows the full reply with a quiet Skimming label")
    func pending() async throws {
        var message = try Self.message(FirstMateSkimFixtures.txnJSON)
        message.skim = FirstMateSkim(status: .pending)
        let render = try await HerdrRenderHarness.render("first-mate-skim-pending.png", size: CGSize(width: 760, height: 1000)) {
            chatRow(message, scheme: .dark)
        }
        render.expectSubstantial(minimumBytes: 4_096)
        #expect(FirstMateSkimReader(skim: message.skim, reply: message.text) == nil)
    }

    @Test("Full reply shows the reply as written, with the Skim toggle")
    func fullReply() async throws {
        let message = try Self.message(FirstMateSkimFixtures.txnJSON)
        let state = SkimDisplayState()
        state.toggle(message.id)
        #expect(state.showsFullReply(message.id))
        let render = try await HerdrRenderHarness.render("first-mate-skim-full-reply.png", size: CGSize(width: 760, height: 1000)) {
            chatRow(message, scheme: .dark, state: state)
        }
        render.expectSubstantial(minimumBytes: 4_096)
        let revealed = SkimDisplayState()
        let reader = try #require(FirstMateSkimReader(skim: message.skim, reply: message.text))
        revealed.reveal(message.id, refs: reader.document.anchors[0].refs)
        let highlighted = try await HerdrRenderHarness.render("first-mate-skim-show-in-reply.png", size: CGSize(width: 760, height: 1000)) {
            chatRow(message, scheme: .dark, state: revealed)
        }
        highlighted.expectSubstantial(minimumBytes: 4_096)
    }

    @Test("A HUD answer shows its skim")
    func hud() async throws {
        let message = try Self.message(FirstMateSkimFixtures.centJSON)
        let render = try await HerdrRenderHarness.render("first-mate-skim-hud.png", size: CGSize(width: 520, height: 360)) {
            SkimmableReply(messageID: message.id, reply: message.text, skim: message.skim, style: .hud) {
                PiMarkdownMessageView(source: message.text, isStreaming: false)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(HerdrTheme.elevated)
        }
        render.expectSubstantial(minimumBytes: 4_096)
    }

    @Test("A code phrase opens a wide, highlighted excerpt with Copy code")
    func codePopover() async throws {
        let message = try Self.message()
        let reader = try #require(FirstMateSkimReader(skim: message.skim, reply: message.text))
        let anchor = try #require(reader.document.anchors.first { $0.kind == "code" })
        #expect(reader.isWide(anchor.refs))
        for scheme in [ColorScheme.dark, .light] {
            let palette = ChatProsePalette.firstMate(FirstMatePalette(scheme: scheme))
            let render = try await HerdrRenderHarness.render(
                "first-mate-skim-code-popover-\(scheme == .dark ? "dark" : "light").png",
                size: CGSize(width: 760, height: 560)
            ) {
                SkimExcerptView(reader: reader, refs: anchor.refs, title: anchor.label, close: {}, showInReply: {})
                    .frame(width: 760, alignment: .top)
                    .environment(\.chatProsePalette, palette)
                    .environment(\.colorScheme, scheme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(FirstMatePalette(scheme: scheme).background)
            }
            render.expectSubstantial(minimumBytes: 4_096)
        }
        let preview = reader.preview(for: anchor.refs, kind: anchor.kind)
        #expect(preview.isWide)
        let hover = try await HerdrRenderHarness.render("first-mate-skim-code-preview.png", size: CGSize(width: 540, height: 300)) {
            SkimPreviewCard(preview: preview, hint: "Click to open the original")
                .frame(width: 540)
                .environment(\.chatProsePalette, .firstMate(FirstMatePalette(scheme: .dark)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(HerdrTheme.elevated)
        }
        hover.expectSubstantial(minimumBytes: 4_096)
        let text = try #require(reader.document.anchors.first { $0.kind == "text" })
        let textPreview = try await HerdrRenderHarness.render("first-mate-skim-text-preview.png", size: CGSize(width: 380, height: 200)) {
            SkimPreviewCard(preview: reader.preview(for: text.refs, kind: text.kind), hint: "Click to open the original")
                .frame(width: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(HerdrTheme.elevated)
        }
        textPreview.expectSubstantial(minimumBytes: 2_048)
    }

    @Test("Excerpt code blocks copy the code without fences")
    func excerptCodeCopy() throws {
        let message = try Self.message()
        let reader = try #require(FirstMateSkimReader(skim: message.skim, reply: message.text))
        let code = try #require(reader.segments.first { $0.kind == "code" })
        let body = FirstMateSkimReader.codeBody(reader.text(of: code.id))
        #expect(!body.hasPrefix("```"))
        #expect(!body.hasSuffix("```"))
        let styled = SkimCodeStyling.highlighted(body, language: code.lang, palette: .chat, scheme: .dark)
        #expect(String(styled.characters) == body)
    }

    // MARK: - Pixels

    private func skimBitmap(of render: HerdrRenderHarness.RenderResult) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: render.url)
        return try #require(NSBitmapImageRep(data: data))
    }

    private func skimRGB(_ color: Color) throws -> (Int, Int, Int) {
        let resolved = try #require(NSColor(color).usingColorSpace(.sRGB))
        return (Int((resolved.redComponent * 255).rounded()), Int((resolved.greenComponent * 255).rounded()),
                Int((resolved.blueComponent * 255).rounded()))
    }

    private func skimPixelCount(in bitmap: NSBitmapImageRep, matching color: (Int, Int, Int), tolerance: Int = 30) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int((pixel.redComponent * 255).rounded())
                let g = Int((pixel.greenComponent * 255).rounded())
                let b = Int((pixel.blueComponent * 255).rounded())
                if abs(r - color.0) <= tolerance, abs(g - color.1) <= tolerance, abs(b - color.2) <= tolerance { count += 1 }
            }
        }
        return count
    }
}
