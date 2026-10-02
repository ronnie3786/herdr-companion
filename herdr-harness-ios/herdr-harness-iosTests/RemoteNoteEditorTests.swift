import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

@Suite("Mobile note editor", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct RemoteNoteEditorTests {
    @Test("Inline patterns match Mac and do not leak into following typing", arguments: ["**bold**", "*italic*", "_italic_", "~~done~~", "**👩🏽‍💻 café**"])
    func patterns(token: String) {
        let (window, editor) = makeEditor()
        defer { window.isHidden = true }
        for character in "Before \(token) after" {
            if !editor.convertMarkdown(in: editor.selectedRange, replacement: String(character)) {
                editor.insertText(String(character))
            }
        }
        let expected = token.filter { !"*_~".contains($0) }
        #expect(editor.text == "Before \(expected) after")
        let format: HerdrNoteTextStyle.Format = token.hasPrefix("**") ? .bold : token.hasPrefix("~~") ? .strikethrough : .italic
        #expect(HerdrNoteTextStyle.contains(format, in: editor.textStorage.attributes(at: 7, effectiveRange: nil)))
        #expect(!HerdrNoteTextStyle.contains(format, in: editor.textStorage.attributes(at: editor.textStorage.length - 1, effectiveRange: nil)))
    }

    @Test("Markdown conversion, later typing, and selection formatting undo independently")
    func undoAndSelection() throws {
        let (window, editor) = makeEditor()
        defer { window.isHidden = true }
        editor.textStorage.setAttributedString(NSAttributedString(string: "Before **hello* after", attributes: HerdrNoteTextStyle.attributes([:], ink: .black)))
        editor.selectedRange = NSRange(location: 15, length: 0)
        let undo = try #require(editor.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(editor.convertMarkdown(in: editor.selectedRange, replacement: "*"))
        undo.endUndoGrouping()
        #expect(editor.text == "Before hello after")
        #expect(editor.selectedRange.location == 12)
        undo.beginUndoGrouping()
        editor.insertText("!")
        undo.endUndoGrouping()
        #expect(editor.text == "Before hello! after")
        undo.undo()
        #expect(editor.text == "Before hello after")
        undo.undo()
        #expect(editor.text == "Before **hello* after")
        undo.redo()
        #expect(editor.text == "Before hello after")
        editor.selectedRange = NSRange(location: 7, length: 5)
        undo.beginUndoGrouping()
        editor.toggle(.underline)
        undo.endUndoGrouping()
        #expect(editor.isActive(.bold))
        #expect(editor.isActive(.underline))
        undo.undo()
        #expect(editor.isActive(.bold))
        #expect(!editor.isActive(.underline))
    }

    @Test("Older Mac typography becomes a semantic body font without losing emphasis or links")
    func legacyStyle() throws {
        var legacy = AttributedString("Shared note")
        legacy.font = .system(size: 42).bold().italic()
        legacy.foregroundColor = .white
        legacy.backgroundColor = .red
        legacy.underlineStyle = .single
        legacy.strikethroughStyle = .single
        legacy.link = URL(string: "https://example.invalid/note")
        let native = HerdrNoteTextStyle.native(legacy, ink: .black)
        #expect((native.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize == HerdrNoteTextStyle.fontSize)
        #expect(native.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        let rich = HerdrNoteTextStyle.rich(native)
        let data = try JSONEncoder().encode(rich, configuration: AttributeScopes.SwiftUIAttributes.self)
        let decoded = try JSONDecoder().decode(AttributedString.self, from: data, configuration: AttributeScopes.SwiftUIAttributes.self)
        let roundTrip = HerdrNoteTextStyle.native(decoded, ink: .black)
        for format in HerdrNoteTextStyle.Format.allCases {
            #expect(HerdrNoteTextStyle.contains(format, in: roundTrip.attributes(at: 0, effectiveRange: nil)))
        }
        #expect(decoded.runs.first?.link == legacy.link)
    }

    @Test("The full phone and tablet editor align text and preserve opening without changes", arguments: [393.0, 700.0])
    func hostedEditor(width: Double) async throws {
        let note = try JSONDecoder().decode(RemoteNote.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"Room to think","body":"A little more clarity\n\nOne font. Bold, italic, and underline, right where you need them.","color":"yellow","createdAt":1000,"updatedAt":1000}"#.utf8))
        let host = UIHostingController(rootView: RemoteNoteEditorView(note: note) { _, _ in })
        let window = makeWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: 760)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(descendants(host.view).compactMap { $0 as? RemoteNoteTextView }.first)
        #expect(editor.text == note.body)
        #expect(editor.backgroundColor == .clear)
        #expect(editor.allowsEditingTextAttributes)
        #expect(editor.textFormattingConfiguration?.groups.flatMap(\.components).map(\.componentKey) == [.fontAttributes])
        #expect(editor.textContainer.lineFragmentPadding == 0)
        #expect(editor.textContainerInset.left == 0)
        #expect(editor.bounds.width > width - 90)
        #expect(editor.bounds.height > 350)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        if let folder = ProcessInfo.processInfo.environment["HERDR_NOTE_PREVIEW_DIR"] {
            try image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("ios-note-\(Int(width)).png"))
        }

    }

    private func makeWindow() -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return UIWindow(windowScene: scene)
        }
        return UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 760))
    }
    private func makeEditor() -> (UIWindow, RemoteNoteTextView) {
        let window = makeWindow()
        let controller = UIViewController()
        let editor = RemoteNoteTextView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        controller.view.addSubview(editor)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        editor.becomeFirstResponder()
        editor.typingAttributes = HerdrNoteTextStyle.attributes([:], ink: .black)
        return (window, editor)
    }
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
