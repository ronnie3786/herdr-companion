import AppKit
import Foundation

/// User-initiated actions for one saved First Mate link.
///
/// Both actions re-validate the stored URL before touching the system. Tests
/// inject the opener and pasteboard so no destination is contacted.
@MainActor
enum FirstMateLinkActions {
    /// Opens the saved destination only after explicit user action.
    @discardableResult
    static func open(_ link: FirstMateLink) -> Bool {
        open(link, opener: { NSWorkspace.shared.open($0) })
    }

    /// Opens through an injected opener. Returns `false` for a non-HTTP(S) or
    /// malformed value without calling the opener.
    @discardableResult
    static func open(_ link: FirstMateLink, opener: @MainActor (URL) -> Bool) -> Bool {
        guard let destination = link.destination else { return false }
        return opener(destination)
    }

    /// Copies the exact saved destination to the general pasteboard.
    @discardableResult
    static func copy(_ link: FirstMateLink) -> Bool {
        copy(link, pasteboard: .general)
    }

    /// Copies to an injected pasteboard. The stored string is written, so a
    /// path, port, query, or fragment is never re-derived from a title,
    /// feature, or repository guess.
    @discardableResult
    static func copy(_ link: FirstMateLink, pasteboard: NSPasteboard) -> Bool {
        guard link.destination != nil else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(link.url, forType: .string)
    }
}

/// The two surfaces that lead with pull requests.
enum FirstMateLinkSurface: String, Sendable {
    case overview
    case documents

    var accessibilitySuffix: String { rawValue }
}
