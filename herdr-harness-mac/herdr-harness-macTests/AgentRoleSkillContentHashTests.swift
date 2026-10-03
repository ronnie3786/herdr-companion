import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Role skill content hash")
struct AgentRoleSkillContentHashTests {
    /// Expected values come from the companion's `content_hash` and `json.dumps`.
    @Test("Hashes match the companion for paths that need escaping and code-point ordering")
    func matchesCompanion() {
        let files: [AgentRoleSkillContentHash.File] = [
            .init(path: "SKILL.md", executable: false,
                  data: Data("---\nname: Sample skill\ndescription: A synthetic skill for hashing.\n---\n\nUse the sample steps.\n".utf8)),
            .init(path: "scripts/run.sh", executable: true, data: Data("#!/bin/sh\necho sample\n".utf8)),
            .init(path: "B-notes.md", executable: false, data: Data("Uppercase sorts before lowercase.\n".utf8)),
            .init(path: "docs/\u{e9}t\u{e9} \"quoted\" \\ tab\t\u{1F600}.txt", executable: false, data: Data([0, 1, 2, 255])),
            .init(path: "docs/e\u{301}-decomposed\u{7f}\u{1}.md", executable: false, data: Data()),
        ]
        #expect(AgentRoleSkillContentHash.hash(files) == "c3b4485fd08f099768e6fb3fa6136197e8253dc68698de5421cdf5ea3a38fed9")
        #expect(AgentRoleSkillContentHash.hash(files.reversed()) == AgentRoleSkillContentHash.hash(files))
        #expect(AgentRoleSkillContentHash.jsonString("docs/\u{e9}t\u{e9} \"quoted\" \\ tab\t\u{1F600}.txt")
                == python(#""docs/U+00e9tU+00e9 \"quoted\" \\ tab\tU+d83dU+de00.txt""#))
        #expect(AgentRoleSkillContentHash.jsonString("docs/e\u{301}-decomposed\u{7f}\u{1}.md")
                == python(#""docs/eU+0301-decomposedU+007fU+0001.md""#))
        #expect(AgentRoleSkillContentHash.jsonString("a\r\n\u{8}\u{c}/b") == #""a\r\n\b\f/b""#)
    }

    /// Spells the backslash-u escapes Python writes as `U+XXXX` in the source.
    private func python(_ text: String) -> String { text.replacingOccurrences(of: "U+", with: "\\u") }

    @Test("Packages hash their decoded files; damaged content has no hash")
    func bundles() {
        let bundle = AgentRoleSkillBundle(id: "skill_alpha", name: "Atlas notes", description: "Synthetic skill.", source: "personal",
            files: [.init(path: "SKILL.md", content: Data("Synthetic skill".utf8).base64EncodedString(), executable: false)])
        #expect(AgentRoleSkillContentHash.hash(bundle) == "fbb0f407af849b41e2147646f617864d358733fbc74bb8fb2fb6d4d1e80462e6")
        let damaged = AgentRoleSkillBundle(id: "skill_alpha", name: "Atlas notes", description: "Synthetic skill.", source: "personal",
            files: [.init(path: "SKILL.md", content: "not base64!", executable: false)])
        #expect(AgentRoleSkillContentHash.hash(damaged) == nil)
    }
}
