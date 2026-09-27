import CryptoKit
import Foundation
@testable import herdr_harness_ios

/// Entirely synthetic skims. Replies are assembled from blocks, so segment
/// offsets (UTF-16), line numbers, and the reply hash always match what the
/// companion would send for that exact text.
enum SkimFixture {
    struct Block {
        let kind: String
        let text: String
        var lang: String? = nil
        /// Text between the previous block and this one.
        var separator = "\n\n"
    }

    static func reply(_ blocks: [Block]) -> String {
        blocks.enumerated().map { $0.offset == 0 ? $0.element.text : $0.element.separator + $0.element.text }.joined()
    }

    static func segments(_ blocks: [Block]) -> [SkimSegment] {
        var segments: [SkimSegment] = []
        var offset = 0
        var line = 1
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                offset += block.separator.utf16.count
                line += block.separator.filter { $0 == "\n" }.count
            }
            let length = block.text.utf16.count
            let lines = block.text.filter { $0 == "\n" }.count
            segments.append(SkimSegment(
                id: "s\(index + 1)", n: index + 1, kind: block.kind,
                startLine: line, endLine: line + lines, start: offset, end: offset + length,
                words: block.text.split(whereSeparator: \.isWhitespace).count,
                section: nil, lang: block.lang,
                codeLines: block.kind == "code" ? max(0, lines - 1) : nil,
                rows: nil, ordered: block.kind == "item" ? false : nil, level: nil, pseudo: nil
            ))
            offset += length
            line += lines
        }
        return segments
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - First Mate: a checkout change

    static let checkoutBlocks: [Block] = [
        Block(kind: "paragraph", text: "Checkout now reserves stock before it charges the card, so two shoppers can no longer buy the last unit at the same moment."),
        Block(kind: "paragraph", text: "The reservation runs inside the order transaction. When the payment provider declines the card, the hold is released before the error reaches the client:"),
        Block(kind: "code", text: """
        ```js
        async function checkout(cart, card) {
          const hold = await inventory.reserve(cart.items);
          try {
            return await payments.charge(card, cart.total);
          } catch (error) {
            await inventory.release(hold); // declined: give the stock back
            throw error;
          }
        }
        ```
        """, lang: "js"),
        Block(kind: "item", text: "- Retries reuse the same hold id, so a double tap never reserves twice."),
        Block(kind: "item", text: "- Holds expire after 15 minutes if the app closes mid-checkout.", separator: "\n"),
        Block(kind: "paragraph", text: "I haven't run the load test against the new transaction yet, so contention under heavy traffic is unverified."),
        Block(kind: "paragraph", text: "Want me to add a test for the declined-card path?"),
    ]

    static var checkoutReply: String { reply(checkoutBlocks) }

    static var checkoutDocument: SkimDocument {
        SkimDocument(
            blocks: [
                .line(kind: "say", tokens: [
                    .text("Checkout now "),
                    .anchor(id: "a1", label: [.text("reserves stock first")], refs: ["s1"]),
                    .text(", and "),
                    .anchor(id: "a2", label: [.text("a declined card")], refs: ["s2", "s3"]),
                    .text(" releases the hold inside "),
                    .anchor(id: "a3", label: [.code("checkout()")], refs: ["s3"]),
                    .text("."),
                ]),
                .line(kind: "heads_up", tokens: [
                    .text("I haven't "),
                    .anchor(id: "a4", label: [.text("load-tested it")], refs: ["s6"]),
                    .text(" yet."),
                ]),
                .line(kind: "ask", tokens: [
                    .text("Want me to add "),
                    .anchor(id: "a5", label: [.text("a declined-card test")], refs: ["s7"]),
                    .text("?"),
                ]),
            ],
            rest: SkimRest(refs: ["s4", "s5"]),
            anchors: [
                SkimAnchor(id: "a1", label: "reserves stock first", refs: ["s1"], kind: "text"),
                SkimAnchor(id: "a2", label: "a declined card", refs: ["s2", "s3"], kind: "code"),
                SkimAnchor(id: "a3", label: "checkout()", refs: ["s3"], kind: "code"),
                SkimAnchor(id: "a4", label: "load-tested it", refs: ["s6"], kind: "text"),
                SkimAnchor(id: "a5", label: "a declined-card test", refs: ["s7"], kind: "text"),
            ],
            stats: SkimStats(sourceWords: words(checkoutReply), skimWords: 24)
        )
    }

    static func checkoutSkim(_ status: FirstMateSkim.Status = .ready, hashed: Bool = true) -> FirstMateSkim {
        guard status == .ready else { return FirstMateSkim(status: status) }
        return FirstMateSkim(
            status: .ready,
            document: checkoutDocument,
            segments: segments(checkoutBlocks),
            replySHA256: hashed ? sha256(checkoutReply) : nil
        )
    }

    static func checkoutReader() -> FirstMateSkimReader? {
        FirstMateSkimReader(skim: checkoutSkim(), reply: checkoutReply)
    }

    static func checkoutMessage(skim: FirstMateSkim?, id: String = "fm-synthetic-reply") -> FirstMateMessage {
        FirstMateMessage(
            id: id, featureID: "fm-synthetic-feature", role: "assistant", text: checkoutReply,
            status: "delivered", createdAt: "2026-09-26T12:00:00Z", visibility: "conversation", skim: skim
        )
    }

    // MARK: - HUD chat: a flaky upload test

    static let uploadBlocks: [Block] = [
        Block(kind: "paragraph", text: "The flaky upload test fails because every test shares one retry timer, so a slow test leaves the timer running into the next one."),
        Block(kind: "code", text: """
        ```diff
        @@ -12,7 +12,7 @@ describe("upload", () => {
        -  const timer = sharedTimer;
        +  const timer = createTimer();
           await upload(file, { timer });
        ```
        """, lang: "diff"),
        Block(kind: "paragraph", text: "With a timer per test, the suite passed 50 runs in a row on the simulator:"),
        Block(kind: "code", text: """
        ```
        ✔ upload retries after a timeout (41 ms)
        ✔ upload gives up after three tries (12 ms)
        ℹ tests 2, pass 2, fail 0
        ```
        """),
        Block(kind: "paragraph", text: "Next I would open a pull request with the fix and a note about the shared timer."),
    ]

    static var uploadReply: String { reply(uploadBlocks) }

    static func uploadSkim(_ status: FirstMateSkim.Status = .ready) -> FirstMateSkim {
        guard status == .ready else { return FirstMateSkim(status: status) }
        let document = SkimDocument(
            blocks: [
                .line(kind: "say", tokens: [
                    .text("The upload test is flaky because "),
                    .anchor(id: "a1", label: [.text("every test shares one retry timer")], refs: ["s1"]),
                    .text("; "),
                    .anchor(id: "a2", label: [.text("a timer per test")], refs: ["s2"]),
                    .text(" made "),
                    .anchor(id: "a3", label: [.text("50 runs in a row pass")], refs: ["s3", "s4"]),
                    .text("."),
                ]),
                .line(kind: "next", tokens: [
                    .text("Open "),
                    .anchor(id: "a4", label: [.text("a pull request with the fix")], refs: ["s5"]),
                    .text("."),
                ]),
            ],
            anchors: [
                SkimAnchor(id: "a1", label: "every test shares one retry timer", refs: ["s1"], kind: "text"),
                SkimAnchor(id: "a2", label: "a timer per test", refs: ["s2"], kind: "code"),
                SkimAnchor(id: "a3", label: "50 runs in a row pass", refs: ["s3", "s4"], kind: "code"),
                SkimAnchor(id: "a4", label: "a pull request with the fix", refs: ["s5"], kind: "text"),
            ],
            stats: SkimStats(sourceWords: words(uploadReply), skimWords: 22)
        )
        return FirstMateSkim(status: .ready, document: document, segments: segments(uploadBlocks),
                             replySHA256: sha256(uploadReply))
    }

    /// A completed HUD chat turn decoded from JSON, the way the companion serves it.
    static func uploadRun(skimJSON: Any?) throws -> HeadlessAgentRun {
        var object: [String: Any] = [
            "id": "agr_synthetic_upload",
            "status": "completed",
            "mode": "act",
            "profile": "hud-chat-v1",
            "prompt": "Why is the upload test flaky?",
            "response": uploadReply,
            "error": NSNull(),
            "createdAt": "2026-09-26T12:00:00Z",
            "threadRootRunId": "agr_synthetic_upload",
            "cwd": "/srv/example",
        ]
        if let skimJSON { object["skim"] = skimJSON }
        return try JSONDecoder().decode(HeadlessAgentRun.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The wire JSON for a skim, as the companion's projection writes it.
    static func json(_ skim: FirstMateSkim) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(skim))
    }
}
