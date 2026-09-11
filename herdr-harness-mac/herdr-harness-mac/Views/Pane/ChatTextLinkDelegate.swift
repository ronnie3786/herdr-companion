import AppKit
import SwiftUI

/// TextKit's default link handler opens the browser. Route through the same
/// SwiftUI OpenURLAction as non-quotable Text so in-app pane links stay in-app.
@MainActor
final class ChatTextLinkDelegate: NSObject, NSTextViewDelegate {
    var openURL: OpenURLAction

    init(openURL: OpenURLAction) { self.openURL = openURL }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        openURL(url)
        return true
    }
}
