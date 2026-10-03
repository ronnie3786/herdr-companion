import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles skill search")
struct AgentRoleSkillSearchTests {
    private static func skill(_ name: String, _ description: String = "Synthetic skill for search tests.",
                              source: String = "personal") -> AgentRoleSkill {
        AgentRoleSkill(id: "skill-" + name, name: name, description: description, source: source,
                       path: "/example/skills/\(name)/SKILL.md", estimatedTokens: 10)
    }

    private let search = AgentRoleSkillSearch([
        skill("swiftui-pro", "Review SwiftUI views for modern APIs."),
        skill("swift-concurrency", "Async and await guidance."),
        skill("pfw-composable-architecture", "Reducer patterns and testing."),
        skill("sizzle-reel", "Narrated explainer video pipeline that mentions swift work in passing."),
        skill("mobile-app-hub", "Publish installable builds.", source: "project"),
        skill("Écrire notes", "Organize synthetic notes."),
        skill("42-checks", "Numbered verification steps."),
    ])

    private func names(_ query: String, source: String = "") -> [String] {
        search.sections(query: query, source: source).flatMap(\.skills).map(\.name)
    }

    @Test("Browsing returns alphabetical letter sections with digits under #")
    func browse() {
        let sections = search.sections(query: "  ", source: "")
        #expect(sections.map(\.id) == ["#", "E", "M", "P", "S"])
        #expect(sections.last?.skills.map(\.name) == ["sizzle-reel", "swift-concurrency", "swiftui-pro"])
        #expect(search.sections(query: "", source: "project").map(\.id) == ["M"])
    }

    @Test("Letters typed in order match across words, best match first")
    func fuzzyOrder() {
        #expect(names("swui").first == "swiftui-pro")
        #expect(names("pfwca").first == "pfw-composable-architecture")
        #expect(names("mah").first == "mobile-app-hub")
        #expect(names("swiftuipro") == ["swiftui-pro"])
    }

    @Test("Name matches outrank description matches")
    func nameBeforeDescription() {
        let results = names("swift")
        #expect(Array(results.prefix(2)).sorted() == ["swift-concurrency", "swiftui-pro"])
        #expect(results.last == "sizzle-reel")
    }

    @Test("Small typos still find the skill")
    func typos() {
        #expect(names("cocnurrency").first == "swift-concurrency")
        #expect(names("concurency").first == "swift-concurrency")
        #expect(names("composible").first == "pfw-composable-architecture")
    }

    @Test("Every word must match; punctuation, case, and accents are ignored")
    func tokens() {
        #expect(names("swift pro") == ["swiftui-pro"])
        #expect(names("SWIFTUI_PRO") == ["swiftui-pro"])
        #expect(names("ecrire") == ["Écrire notes"])
        #expect(names("42") == ["42-checks"])
        #expect(names("swift zzzz").isEmpty)
        #expect(search.sections(query: "swift zzzz", source: "").isEmpty)
    }

    @Test("Very short queries match word starts, not scattered letters")
    func shortQueries() {
        #expect(names("ap").contains("mobile-app-hub"))
        #expect(!names("ap").contains("pfw-composable-architecture"))
        #expect(names("sc") == ["swift-concurrency"])
    }

    @Test("The source filter applies to ranked results")
    func sourceFilter() {
        #expect(names("hub", source: "project") == ["mobile-app-hub"])
        #expect(names("hub", source: "personal").isEmpty)
    }

    @Test("Ranking 2,000 skills stays fast")
    func largeCatalog() {
        let skills = (0..<2000).map { index in
            Self.skill("synthetic-skill-\(index)", String(repeating: "Synthetic description words. ", count: 40))
        }
        let search = AgentRoleSkillSearch(skills)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for query in ["s", "sy", "syn", "synthetic 19", "skil 7", "zzzz"] { _ = search.sections(query: query, source: "") }
        }
        #expect(search.sections(query: "synthetic skill 1999", source: "").first?.skills.first?.name == "synthetic-skill-1999")
        #expect(elapsed < .seconds(2))
    }
}
