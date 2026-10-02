import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles local skill packages")
struct AgentRoleSkillCatalogTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-role-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(_ directory: URL, name: String = "synthetic-review") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: Review a synthetic example.\n---\nExample body.\n".utf8)
            .write(to: directory.appendingPathComponent("SKILL.md"))
    }

    private func source(_ root: URL, id: String = "synthetic", name: String = "Examples") -> AgentRoleCatalogSource {
        .init(id: id, name: name, path: root.path)
    }

    @Test("Frontmatter supports folded, literal, quoted, and fallback values")
    func frontmatter() throws {
        let folded = try #require(AgentRoleCatalogScanner.metadata("""
        ---
        name: 'synthetic-review'
        description: >-
          Review a synthetic example
          and explain the result.
        ---
        Do not use body text as a description.
        """, fallbackName: "fallback"))
        #expect(folded.name == "synthetic-review")
        #expect(folded.description == "Review a synthetic example and explain the result.")
        let literal = try #require(AgentRoleCatalogScanner.metadata("---\ndescription: |\n  First line.\n  Second line.\n---\n", fallbackName: "fallback"))
        #expect(literal.name == "fallback")
        #expect(literal.description == "First line.\nSecond line.")
        let quoted = try #require(AgentRoleCatalogScanner.metadata("---\ndescription: \"Read \\\"example\\\" files.\"\n---\n", fallbackName: "fallback"))
        #expect(quoted.description == "Read \"example\" files.")
        #expect(AgentRoleCatalogScanner.metadata("---\nname: missing-description\n---\n", fallbackName: "fallback") == nil)
    }

    @Test("Scanning deduplicates real files and retains stable source identities")
    func scanIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("skills")
        let package = skills.appendingPathComponent("nested/example")
        try writeSkill(package)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: skills)
        let result = AgentRoleCatalogScanner.scan([source(skills), source(alias, id: "duplicate")])
        #expect(result.skills.count == 1)
        #expect(result.sources.allSatisfy { $0.available })
        #expect(result.warnings.isEmpty)
        let skill = try #require(result.skills.first)
        #expect(skill.id.hasPrefix("skill_"))
        #expect(skill.id.count == 70)
        #expect(skill.source == "synthetic")
        #expect(skill.estimatedTokens > 0)
        let renamed = AgentRoleCatalogScanner.scan([source(skills, name: "A different label")])
        #expect(renamed.skills.first?.id == skill.id)
    }

    @Test("A symlinked package is copied with supporting binary files and executable scripts")
    func packageContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcesRoot = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("package")
        try writeSkill(package)
        let script = package.appendingPathComponent("check.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let binary = Data([0, 1, 2, 255])
        try binary.write(to: package.appendingPathComponent("sample.bin"))
        try Data("synthetic secret".utf8).write(to: package.appendingPathComponent(".env"))
        try Data("synthetic credentials".utf8).write(to: package.appendingPathComponent("credentials.json"))
        try FileManager.default.createSymbolicLink(at: sourcesRoot.appendingPathComponent("example"), withDestinationURL: package)
        let inputs = [source(sourcesRoot)]
        let result = AgentRoleCatalogScanner.scan(inputs)
        #expect(result.skills.count == 1)
        let bundles = try AgentRoleCatalogScanner.bundles(Array(result.packages.values), sources: inputs)
        let bundle = try #require(bundles.first)
        #expect(Set(bundle.files.map(\.path)) == ["SKILL.md", "check.sh", "sample.bin"])
        #expect(bundle.files.first(where: { $0.path == "check.sh" })?.executable == true)
        #expect(bundle.files.first(where: { $0.path == "SKILL.md" })?.executable == false)
        let encoded = try #require(bundle.files.first(where: { $0.path == "sample.bin" })?.content)
        #expect(Data(base64Encoded: encoded) == binary)
    }

    @Test("A link outside a selected package is rejected instead of copying unrelated files")
    func escapingLink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try writeSkill(package)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("Unrelated synthetic text".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("reference.txt"), withDestinationURL: outside)
        let inputs = [source(package)]
        let result = AgentRoleCatalogScanner.scan(inputs)
        #expect(throws: AgentRoleCatalogError.self) {
            try AgentRoleCatalogScanner.bundles(Array(result.packages.values), sources: inputs)
        }
    }

    @Test("A moved symlink or removed SKILL.md requires a refresh")
    func changedPackage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let replacement = root.appendingPathComponent("replacement")
        try writeSkill(original)
        try writeSkill(replacement)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let inputs = [source(alias)]
        let result = AgentRoleCatalogScanner.scan(inputs)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        #expect(throws: AgentRoleCatalogError.self) {
            try AgentRoleCatalogScanner.bundles(Array(result.packages.values), sources: inputs)
        }
        let refreshed = AgentRoleCatalogScanner.scan(inputs)
        try FileManager.default.removeItem(at: replacement.appendingPathComponent("SKILL.md"))
        #expect(throws: AgentRoleCatalogError.self) {
            try AgentRoleCatalogScanner.bundles(Array(refreshed.packages.values), sources: inputs)
        }
    }

    @Test("Unavailable roots do not hide valid sources, and oversized files cannot upload")
    func unavailableAndOversized() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try writeSkill(package)
        let inputs = [source(package), source(root.appendingPathComponent("missing"), id: "missing")]
        let result = AgentRoleCatalogScanner.scan(inputs)
        #expect(result.skills.count == 1)
        #expect(result.sources.last?.available == false)
        #expect(result.warnings.count == 1)
        try Data(repeating: 0, count: AgentRoleCatalogScanner.maxFileBytes + 1)
            .write(to: package.appendingPathComponent("oversized.bin"))
        #expect(throws: AgentRoleCatalogError.self) {
            try AgentRoleCatalogScanner.bundles(Array(result.packages.values), sources: inputs)
        }
    }

    @MainActor
    @Test("Local source removal persists and stale selections cannot be uploaded")
    func sourcePersistence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(root.appendingPathComponent(".agents/skills/example"))
        let suite = "AgentRoleSkillCatalogTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = AgentRoleLocalCatalog(defaults: defaults, home: root)
        await catalog.refresh()
        let id = try #require(catalog.skills.first?.id)
        let bundles = try await catalog.bundles(for: [id])
        #expect(bundles.count == 1)
        catalog.removeSource("agents")
        #expect(catalog.skills.isEmpty)
        #expect(AgentRoleLocalCatalog(defaults: defaults, home: root).sources.map(\.id) == ["pi"])
        await #expect(throws: AgentRoleCatalogError.self) { try await catalog.bundles(for: [id]) }
    }
}
