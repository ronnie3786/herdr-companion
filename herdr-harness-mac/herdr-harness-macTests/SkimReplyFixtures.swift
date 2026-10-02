import CryptoKit
import Foundation
@testable import herdr_harness_mac

enum SkimReplyFixtures {
    static let paragraphs = [
        "I found why recovery stopped: the saved checkpoint still points to the previous session, so the current worker cannot resume from it. The saved files and verification records are intact.",
        "The recovery path needs to restore that checkpoint into the current session before continuing. That keeps the recorded plan and the files already written together, without repeating the completed work.",
        "The existing tests cover starting from an empty session. I would add a regression test for restoring a checkpoint after a session handoff, then verify the recovered files before proceeding.",
        "Reply with recover it and I will restore the saved checkpoint. Or reply revise it and I will revise the recovery plan first."
    ]
    static let reply = paragraphs.joined(separator: "\n\n")
    static let actions = [
        SkimReplyAction(id: "r1", label: "recover it", explanation: "Ask the agent to restore the saved checkpoint and continue from it.", refs: ["s4"]),
        SkimReplyAction(id: "r2", label: "revise it", explanation: "Ask the agent to revise the recovery plan before making changes.", refs: ["s4"])
    ]

    static var skim: FirstMateSkim {
        var offset = 0
        let segments = paragraphs.enumerated().map { index, text in
            defer { offset += text.utf16.count + 2 }
            return SkimSegment(id: "s\(index + 1)", n: index + 1, kind: "paragraph", startLine: index * 2 + 1,
                               endLine: index * 2 + 1, start: offset, end: offset + text.utf16.count)
        }
        let tokens: [SkimToken] = [
            .text("Recovery stopped because "),
            .anchor(id: "a1", label: [.text("the checkpoint targets an old session")], refs: ["s1"]),
            .text(". I can "),
            .anchor(id: "a2", label: [.text("restore it safely")], refs: ["s2", "s3"]),
            .text(" while preserving the saved work, verify the recovered files, and continue without repeating completed steps.")
        ]
        let nextStep = "Recover the checkpoint or revise the plan first?"
        let skimWords = (tokens.map(\.plainText).joined() + " " + nextStep).split(whereSeparator: \.isWhitespace).count
        let document = SkimDocument(format: "breath_balanced", blocks: [
            .line(kind: "say", tokens: tokens),
            .line(kind: "ask", tokens: [.text(nextStep)])
        ], rest: .init(refs: ["s4"]), anchors: [
            SkimAnchor(id: "a1", label: "the checkpoint targets an old session", refs: ["s1"], kind: "text"),
            SkimAnchor(id: "a2", label: "restore it safely", refs: ["s2", "s3"], kind: "text")
        ], stats: SkimStats(sourceWords: reply.split(whereSeparator: \.isWhitespace).count, skimWords: skimWords), actions: actions)
        return FirstMateSkim(status: .ready, format: "breath_balanced", promptVersion: "skim-v3", document: document,
                             segments: segments, replySHA256: SHA256.hash(data: Data(reply.utf8)).map { String(format: "%02x", $0) }.joined())
    }
}
