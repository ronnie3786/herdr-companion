import CryptoKit
import Foundation
import Observation

@MainActor
protocol AgentRoleSkillCatalog: AnyObject {
    var sources: [AgentRoleSkillSource] { get }
    var skills: [AgentRoleSkill] { get }
    var errorMessage: String? { get }
    var issues: [AgentRoleSkillIssue] { get }
    var suggestedSources: [AgentRoleSkillSource] { get }
    var isLoading: Bool { get }
    func refresh() async
    func addSource(_ url: URL, name: String?) throws
    func removeSource(_ id: String)
    func bundles(for skillIDs: Set<String>) async throws -> [AgentRoleSkillBundle]
}

extension AgentRoleSkillCatalog {
    var issues: [AgentRoleSkillIssue] { [] }
    var suggestedSources: [AgentRoleSkillSource] { [] }
}

/// Local folders stay on this Mac. Only packages selected for a role are uploaded.
@MainActor
@Observable
final class AgentRoleLocalCatalog: AgentRoleSkillCatalog {
    private(set) var sources: [AgentRoleSkillSource] = []
    private(set) var skills: [AgentRoleSkill] = []
    private(set) var errorMessage: String?
    private(set) var issues: [AgentRoleSkillIssue] = []
    private(set) var suggestedSources: [AgentRoleSkillSource] = []
    private(set) var isLoading = false

    private let defaults: UserDefaults
    private let userHome: URL?
    private var records: [AgentRoleCatalogSource]
    private var packages: [String: AgentRoleCatalogPackage] = [:]
    private var generation = 0
    private static let defaultsKey = "agentRoles.localSkillSources.v1"

    init(defaults: UserDefaults = .standard, home: URL? = nil) {
        self.defaults = defaults
        let home = home ?? AgentRoleSkillLocations.userHome
        userHome = home
        let suggested = home.map(AgentRoleSkillLocations.defaults) ?? []
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([AgentRoleCatalogSource].self, from: data) {
            // Expand untouched legacy defaults, never re-add folders someone removed.
            if saved.count == 2, Set(saved.map(\.id)) == ["agents", "pi"], saved.allSatisfy({ $0.bookmark == nil }) {
                records = suggested
            } else {
                records = saved.map { source in
                    var source = source
                    if source.name == "skills" {
                        source.name = AgentRoleSkillLocations.label(for: URL(fileURLWithPath: source.path), home: home)
                    }
                    return source
                }
            }
        } else { records = suggested }
        sources = records.filter { !$0.isAutomatic }.map { $0.display(available: false) }
    }

    func refresh() async {
        generation += 1
        let expectedGeneration = generation
        let inputs = records
        isLoading = true
        let result = await Task.detached(priority: .utility) {
            AgentRoleCatalogScanner.scan(inputs)
        }.value
        guard generation == expectedGeneration else { return }
        sources = result.sources
        skills = result.skills
        packages = result.packages
        issues = result.issues
        suggestedSources = result.suggestedSources
        errorMessage = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
        isLoading = false
    }

    /// Call with the directory returned by NSOpenPanel so the sandbox can retain access.
    func addSource(_ url: URL, name: String? = nil) throws {
        let normalized = url.standardizedFileURL
        let bookmark = try normalized.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        let existingIndex = records.firstIndex { URL(fileURLWithPath: $0.path).standardizedFileURL == normalized }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = existingIndex.map { records[$0] }
        let record = AgentRoleCatalogSource(
            id: existing?.id ?? "source-" + UUID().uuidString.lowercased(),
            name: label.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.name
                ?? AgentRoleSkillLocations.label(for: normalized, home: userHome),
            path: normalized.path, bookmark: bookmark)
        if let existingIndex { records[existingIndex] = record }
        else {
            guard records.count < 32 else { throw AgentRoleCatalogError("Use no more than 32 skill folders.") }
            records.append(record)
        }
        persistSources()
    }

    func removeSource(_ id: String) {
        records.removeAll { $0.id == id }
        persistSources()
    }

    func bundles(for skillIDs: Set<String>) async throws -> [AgentRoleSkillBundle] {
        let inputs = records
        let selected = try skillIDs.sorted().map { id in
            guard let package = packages[id] else {
                throw AgentRoleCatalogError("A selected skill is unavailable on this Mac. Refresh the folders or remove it before saving.")
            }
            return package
        }
        return try await Task.detached(priority: .utility) {
            try AgentRoleCatalogScanner.bundles(selected, sources: inputs)
        }.value
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.defaultsKey) }
        generation += 1
        isLoading = false
        let visibleIDs = Set(sources.map(\.id))
        sources = records.filter { !$0.isAutomatic || visibleIDs.contains($0.id) }.map { record in
            sources.first(where: { $0.id == record.id }) ?? record.display(available: false)
        }
        let ids = Set(records.map(\.id))
        packages = packages.filter { ids.contains($0.value.sourceID) }
        skills = skills.filter { packages[$0.id] != nil }
        issues = []
        suggestedSources = suggestedSources.filter { ids.contains($0.id) }
        errorMessage = nil
    }
}

struct AgentRoleCatalogError: LocalizedError {
    let message: String
    let issueKind: AgentRoleSkillIssue.Kind?
    init(_ message: String, issueKind: AgentRoleSkillIssue.Kind? = nil) {
        self.message = message
        self.issueKind = issueKind
    }
    var errorDescription: String? { message }
}

struct AgentRoleCatalogSource: Codable, Sendable {
    let id: String
    var name: String
    let path: String
    var bookmark: Data? = nil
    var automatic: Bool? = nil

    var isAutomatic: Bool { automatic ?? (bookmark == nil && ["agents", "pi"].contains(id)) }

    func display(available: Bool) -> AgentRoleSkillSource {
        .init(id: id, name: name, path: path, available: available)
    }

    func accessURL() throws -> URL {
        let url: URL
        if let bookmark {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                throw AgentRoleCatalogError("Choose the \(name) folder again to renew access.", issueKind: .folderAccess)
            }
            if stale { throw AgentRoleCatalogError("Choose the \(name) folder again to renew access.", issueKind: .folderAccess) }
        } else {
            url = URL(fileURLWithPath: path, isDirectory: true)
        }
        return url
    }

    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try accessURL()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}

struct AgentRoleCatalogPackage: Sendable {
    let skill: AgentRoleSkill
    let sourceID: String
    let relativeDirectory: String
    /// A changed symlink target requires a fresh catalog scan before copying.
    let resolvedDirectory: URL
}

struct AgentRoleCatalogScan: Sendable {
    var sources: [AgentRoleSkillSource] = []
    var skills: [AgentRoleSkill] = []
    var packages: [String: AgentRoleCatalogPackage] = [:]
    var issues: [AgentRoleSkillIssue] = []
    var suggestedSources: [AgentRoleSkillSource] = []
    var warnings: [String] { issues.map { $0.title + ". " + $0.message } }

    mutating func record(_ issue: AgentRoleSkillIssue) {
        if let index = issues.firstIndex(where: { $0.id == issue.id || ($0.needsAccess && issue.needsAccess && $0.path == issue.path) }) {
            issues[index].skillNames.formUnion(issue.skillNames)
            if issue.kind == .linkedFolderAccess { issues[index].kind = .linkedFolderAccess }
        } else { issues.append(issue) }
    }
}

/// Synchronous filesystem work, called only from a utility task by the observable store.
enum AgentRoleCatalogScanner {
    static let maxFiles = 1_000
    static let maxBytes = 8 * 1_024 * 1_024
    static let maxFileBytes = 2 * 1_024 * 1_024
    private static let maxDirectories = 10_000

    static func scan(_ sources: [AgentRoleCatalogSource]) -> AgentRoleCatalogScan {
        withGrantedFolders(sources) { scanAccessibleFolders(sources) }
    }

    /// Keep all granted roots open together. A selected source may link into a
    /// second granted root, during both discovery and package collection.
    private static func withGrantedFolders<T>(_ sources: [AgentRoleCatalogSource], _ body: () throws -> T) rethrows -> T {
        let opened = sources.compactMap { try? $0.accessURL() }
            .filter { $0.startAccessingSecurityScopedResource() }
        defer { opened.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private static func scanAccessibleFolders(_ sources: [AgentRoleCatalogSource]) -> AgentRoleCatalogScan {
        var result = AgentRoleCatalogScan()
        var knownFiles = Set<String>()
        for source in sources {
            do {
                try source.withAccess { root in
                    let manager = FileManager.default
                    // Unlike fileExists, this distinguishes denied sandbox access from an empty folder.
                    _ = try manager.contentsOfDirectory(atPath: root.path)
                    result.sources.append(source.display(available: true))
                    var visited = Set<String>()
                    var remaining = maxDirectories
                    try discover(root, relative: "", source: source, depth: 0, visited: &visited,
                                 remaining: &remaining, knownFiles: &knownFiles, result: &result)
                }
            } catch {
                // A missing conventional folder is normal, not a warning.
                if source.isAutomatic {
                    if !AgentRoleSkillIssue.isMissingError(error) {
                        result.suggestedSources.append(source.display(available: false))
                    }
                    continue
                }
                if !result.sources.contains(where: { $0.id == source.id }) {
                    result.sources.append(source.display(available: false))
                }
                let kind: AgentRoleSkillIssue.Kind = (error as? AgentRoleCatalogError)?.issueKind
                    ?? (AgentRoleSkillIssue.isPermissionError(error) ? .folderAccess : .missingFolder)
                result.record(.init(kind: kind, sourceName: source.name, path: source.path,
                                    detail: (error as? AgentRoleCatalogError)?.message))
            }
        }
        result.skills.sort { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) }
        return result
    }

    private static func discover(_ directory: URL, relative: String, source: AgentRoleCatalogSource,
                                 depth: Int, visited: inout Set<String>, remaining: inout Int,
                                 knownFiles: inout Set<String>, result: inout AgentRoleCatalogScan) throws {
        guard depth <= 12, remaining > 0 else {
            throw AgentRoleCatalogError("\(source.name) exceeds the scan limit. Choose a smaller skill folder.", issueKind: .scanLimit)
        }
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        guard visited.insert(resolved.path).inserted else { return }
        remaining -= 1
        let skillFile = directory.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: skillFile.path) {
            let canonicalFile = skillFile.resolvingSymlinksInPath().standardizedFileURL
            guard isInside(canonicalFile, root: resolved),
                  !knownFiles.contains(canonicalFile.path) else { return }
            do {
                let content = try readFile(canonicalFile, maximum: maxFileBytes)
                guard let text = String(data: content, encoding: .utf8),
                      let metadata = metadata(text, fallbackName: directory.lastPathComponent) else {
                    throw AgentRoleCatalogError("SKILL.md needs UTF-8 text and a frontmatter description.")
                }
                knownFiles.insert(canonicalFile.path)
                let relativeFile = relative.isEmpty ? "SKILL.md" : relative + "/SKILL.md"
                let digest = SHA256.hash(data: Data((source.id + "/" + relativeFile).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let skill = AgentRoleSkill(id: "skill_" + digest, name: metadata.name, description: metadata.description,
                                           source: source.id, path: skillFile.path,
                                           estimatedTokens: max(1, (metadata.name.utf8.count + metadata.description.utf8.count
                                                                      + skillFile.path.utf8.count + 100 + 3) / 4))
                result.skills.append(skill)
                result.packages[skill.id] = .init(skill: skill, sourceID: source.id,
                                                  relativeDirectory: relative, resolvedDirectory: resolved)
            } catch {
                let linked = resolved != directory.standardizedFileURL
                let permission = AgentRoleSkillIssue.isPermissionError(error)
                let folder = linked ? resolved.deletingLastPathComponent() : directory
                result.record(.init(kind: permission ? (linked ? .linkedFolderAccess : .folderAccess) : .unreadableSkill,
                                    sourceName: source.name, path: permission ? folder.path : canonicalFile.path,
                                    skillNames: [directory.lastPathComponent],
                                    detail: (error as? AgentRoleCatalogError)?.message))
            }
            return
        }
        // Foundation's URL enumerator does not follow a final directory symlink on macOS.
        let children = try FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !excluded(child.lastPathComponent) {
            let canonical = child.resolvingSymlinksInPath().standardizedFileURL
            do {
                guard try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                try discover(child, relative: childRelative, source: source, depth: depth + 1, visited: &visited,
                             remaining: &remaining, knownFiles: &knownFiles, result: &result)
            } catch {
                if (error as? AgentRoleCatalogError)?.issueKind == .scanLimit { throw error }
                let linked = canonical != child.standardizedFileURL
                let permission = AgentRoleSkillIssue.isPermissionError(error)
                result.record(.init(kind: permission ? (linked ? .linkedFolderAccess : .folderAccess) : .unreadableSkill,
                                    sourceName: source.name,
                                    path: linked && permission ? canonical.deletingLastPathComponent().path : child.path,
                                    skillNames: [child.lastPathComponent]))
            }
        }
    }

    static func bundles(_ packages: [AgentRoleCatalogPackage], sources: [AgentRoleCatalogSource]) throws -> [AgentRoleSkillBundle] {
        var fileCount = 0
        var byteCount = 0
        return try withGrantedFolders(sources) { try packages.map { package in
            guard let source = sources.first(where: { $0.id == package.sourceID }) else {
                throw AgentRoleCatalogError("A selected skill folder was removed. Refresh the catalog before saving.")
            }
            return try source.withAccess { sourceRoot in
                let directory = package.relativeDirectory.isEmpty ? sourceRoot
                    : sourceRoot.appendingPathComponent(package.relativeDirectory, isDirectory: true)
                let root = directory.resolvingSymlinksInPath().standardizedFileURL
                guard root == package.resolvedDirectory else {
                    throw AgentRoleCatalogError("The \(package.skill.name) folder changed. Refresh the catalog before saving.")
                }
                var files: [AgentRoleSkillFile] = []
                var visited = Set<String>()
                try collect(directory, root: root, relative: "", visited: &visited, files: &files,
                            fileCount: &fileCount, byteCount: &byteCount)
                guard files.contains(where: { $0.path == "SKILL.md" }) else {
                    throw AgentRoleCatalogError("\(package.skill.name) is missing SKILL.md. Refresh the catalog before saving.")
                }
                return .init(id: package.skill.id, name: package.skill.name, description: package.skill.description,
                             source: package.skill.source, files: files)
            }
        }
        }
    }

    private static func collect(_ directory: URL, root: URL, relative: String, visited: inout Set<String>,
                                files: inout [AgentRoleSkillFile], fileCount: inout Int, byteCount: inout Int) throws {
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(canonical, root: root), visited.insert(canonical.path).inserted else {
            throw AgentRoleCatalogError("A selected skill contains a folder link outside its package or a link cycle.")
        }
        defer { visited.remove(canonical.path) }
        let children = try FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])
        var names = Set<String>()
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !excluded(child.lastPathComponent) {
            let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
            guard path.utf8.count <= 512, path.split(separator: "/").count <= 16,
                  !path.contains("\\"), names.insert(child.lastPathComponent.lowercased()).inserted else {
                throw AgentRoleCatalogError("A selected skill contains an unsupported or duplicate file path.")
            }
            let canonicalChild = child.resolvingSymlinksInPath().standardizedFileURL
            guard isInside(canonicalChild, root: root) else {
                throw AgentRoleCatalogError("A selected skill links to a file outside its package. Copy the supporting file into the skill folder first.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: canonicalChild.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                try collect(child, root: root, relative: path, visited: &visited, files: &files,
                            fileCount: &fileCount, byteCount: &byteCount)
            } else {
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw AgentRoleCatalogError("A selected skill contains a file that cannot be copied.")
                }
                let content = try readFile(canonicalChild, maximum: maxFileBytes)
                fileCount += 1
                byteCount += content.count
                guard fileCount <= maxFiles, byteCount <= maxBytes else {
                    throw AgentRoleCatalogError("Selected skills exceed 1,000 files or 8 MB. Select fewer or smaller packages.")
                }
                let mode = attributes[.posixPermissions] as? Int ?? 0
                files.append(.init(path: path, content: content.base64EncodedString(), executable: mode & 0o100 != 0))
            }
        }
    }

    private static func readFile(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximum else {
            throw AgentRoleCatalogError("A selected skill file exceeds 2 MB or is not a regular file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw AgentRoleCatalogError("A selected skill file exceeds 2 MB.") }
        return data
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private static func excluded(_ name: String) -> Bool {
        name.hasPrefix(".") || ["node_modules", "__pycache__", "credentials", "credentials.json", "id_rsa", "id_ed25519"].contains(name.lowercased())
    }

    /// Skill frontmatter needs only two strings. Support ordinary quoted and block scalars.
    static func metadata(_ document: String, fallbackName: String) -> (name: String, description: String)? {
        let lines = document.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var values: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == "name" || key == "description" else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(">") || value.hasPrefix("|") || value.isEmpty {
                let folded = !value.hasPrefix("|")
                var continuation: [String] = []
                while index < end && (lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty) {
                    continuation.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = continuation.joined(separator: folded ? " " : "\n")
            } else {
                while index < end && (lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t")) {
                    value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                if value.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
                    value = decoded
                } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                    value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                } else if let comment = value.range(of: " #") {
                    value = String(value[..<comment.lowerBound])
                }
            }
            values[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let description = values["description"], !description.isEmpty else { return nil }
        let name = values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        guard name.utf8.count <= 200, description.utf8.count <= 4_000 else { return nil }
        return (name, description)
    }
}
