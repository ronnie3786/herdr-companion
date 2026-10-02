import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Skim reply chip renders", .serialized)
@MainActor
struct SkimReplyRenderTests {
    @Test("Main chat skims and chips use the full reading column")
    func mainChat() async throws {
        let result = try await HerdrRenderHarness.render("skim-replies-main-chat.png", size: CGSize(width: 760, height: 330)) {
            PiAssistantMessageView(block: .init(id: "reply", text: SkimReplyFixtures.reply, status: .complete), skim: SkimReplyFixtures.skim)
                .environment(\.skimReplyContext, .init(messageID: "reply", send: { _ in true }))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        result.expectSubstantial(minimumBytes: 4096)
        Attachment.record(try Data(contentsOf: result.url), named: result.name)
    }

    @Test("First Mate chips match both appearances", arguments: [ColorScheme.dark, .light])
    func firstMate(scheme: ColorScheme) async throws {
        let result = try await HerdrRenderHarness.render("skim-replies-first-mate-\(scheme == .dark ? "dark" : "light").png", size: CGSize(width: 760, height: 350)) {
            FirstMateMessageView(message: .init(id: "reply", featureID: "feature", role: "assistant", text: SkimReplyFixtures.reply,
                                                status: "done", createdAt: "2026-01-01T12:00:00Z", skim: SkimReplyFixtures.skim))
                .environment(\.skimReplyContext, .init(messageID: "reply", send: { _ in true }))
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(FirstMatePalette(scheme: scheme).background)
                .environment(\.colorScheme, scheme)
        }
        result.expectSubstantial(minimumBytes: 4096)
        Attachment.record(try Data(contentsOf: result.url), named: result.name)
    }

    @Test("Narrow HUDs wrap chips at the largest text size")
    func narrowHUD() async throws {
        let result = try await HerdrRenderHarness.render("skim-replies-hud-large.png", size: CGSize(width: 360, height: 600)) {
            SkimmableReply(messageID: "reply", reply: SkimReplyFixtures.reply, skim: SkimReplyFixtures.skim, style: .hud) {
                Text(SkimReplyFixtures.reply)
            }
            .environment(\.skimReplyContext, .init(messageID: "reply", send: { _ in true }))
            .environment(\.herdrFontScale, .xxxLarge)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        result.expectSubstantial(minimumBytes: 4096)
        Attachment.record(try Data(contentsOf: result.url), named: result.name)
    }

    @Test("A completed answer with no next step has no reply controls")
    func noOptions() async throws {
        var skim = SkimReplyFixtures.skim
        skim.document?.blocks.removeLast()
        skim.document?.actions = []
        let result = try await HerdrRenderHarness.render("skim-replies-no-options.png", size: CGSize(width: 760, height: 260)) {
            PiAssistantMessageView(block: .init(id: "done", text: SkimReplyFixtures.reply, status: .complete), skim: skim)
                .environment(\.skimReplyContext, .init(messageID: "done", send: { _ in true }))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        result.expectSubstantial(minimumBytes: 4096)
        Attachment.record(try Data(contentsOf: result.url), named: result.name)
    }
}
