import SwiftUI

extension EnvironmentValues {
    @Entry var firstMateMentionCatalog: FirstMateMentionCatalog? = nil
}

/// Content AND catalog identity participate in the bounded cache. A renamed
/// feature or changed crew cannot reuse old mention destinations or labels.
@MainActor
enum FirstMateMentionText {
    private struct Entry {
        var source: String
        var catalog: FirstMateMentionCatalog
        var rendered: AttributedString
    }
    private struct LinkedEntry {
        var source: AttributedString
        var catalog: FirstMateMentionCatalog
        var rendered: AttributedString
    }
    private static var linkedEntries: [LinkedEntry] = []
    private static var entries: [Entry] = []
    static func link(_ source: AttributedString, catalog: FirstMateMentionCatalog?) -> AttributedString {
        guard let catalog else { return source }
        if let cached = linkedEntries.first(where: { $0.source == source && $0.catalog == catalog }) { return cached.rendered }
        let rendered = safelyLink(source, catalog: catalog)
        if source.characters.count <= 8_192, catalog.entries.count <= 256 {
            linkedEntries.append(.init(source: source, catalog: catalog, rendered: rendered))
            while linkedEntries.count > 32 { linkedEntries.removeFirst() }
        }
        return rendered
    }
    /// The shared Mac linker canonicalizes links using its older permissive
    /// mention parser. Never let that erase an explicit phone origin, duplicate
    /// security field, inspector route or invalid grammar before phone routing.
    private static func safelyLink(_ source: AttributedString, catalog: FirstMateMentionCatalog) -> AttributedString {
        var protected = source
        var originals: [URL: URL] = [:]
        let scheme = "herdr-preserved-" + UUID().uuidString.lowercased()
        for (url, range) in source.runs[\.link] {
            guard let url, url.scheme?.lowercased() == "herdr", url.host?.lowercased() == "first-mate" else { continue }
            let canonical = FirstMateMention.parse(url).map(FirstMateMention.url)
            guard FirstMateMobileOpenRequest(url: url) == nil || canonical != url else { continue }
            let placeholder = URL(string: scheme + "://link/\(originals.count)")!
            originals[placeholder] = url
            protected[range].link = placeholder
        }
        var result = FirstMateMentionLinker.link(protected, catalog: catalog)
        let links = result.runs[\.link].map { ($0.0, $0.1) }
        for (url, range) in links {
            if let url, let original = originals[url] { result[range].link = original }
        }
        return result
    }

    static var cachedCount: Int { entries.count }
    static func render(_ source: String, catalog: FirstMateMentionCatalog?) -> AttributedString {
        guard let catalog else { return PiMarkdownText.render(source) }
        if let cached = entries.first(where: { $0.source == source && $0.catalog == catalog }) { return cached.rendered }
        let rendered = safelyLink(PiMarkdownText.render(source), catalog: catalog)
        // Oversized messages are still rendered completely, but not retained.
        if source.utf8.count <= 16_384, catalog.entries.count <= 256 {
            entries.append(.init(source: source, catalog: catalog, rendered: rendered))
            while entries.count > 64 { entries.removeFirst() }
        }
        return rendered
    }
}
