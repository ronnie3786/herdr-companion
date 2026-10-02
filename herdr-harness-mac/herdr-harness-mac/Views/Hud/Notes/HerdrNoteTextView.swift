import AppKit

/// AppKit owns insertion, selection, composition and undo. Markdown conversion
/// is one native replacement, so no SwiftUI update needs to guess cursor offsets.
final class HerdrNoteTextView: NSTextView {
    var ink = NSColor.textColor
    var formatChanged: (() -> Void)?
    var onEscape: (() -> Void)?

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if !hasMarkedText(), range.length == 0,
           let character = insertString as? String, ["*", "_", "~"].contains(character),
           range.location <= (string as NSString).length {
            let prefix = (string as NSString).substring(to: range.location) + character
            if let match = HerdrNoteTextStyle.markdownMatch(in: prefix), let storage = textStorage {
                let content = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: match.contentRange))
                content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { values, run, _ in
                    content.setAttributes(HerdrNoteTextStyle.applying(match.format, enabled: true, to: values, ink: ink), range: run)
                }
                let nextTyping = HerdrNoteTextStyle.attributes(typingAttributes, ink: ink)
                // The closing character has not yet been inserted.
                super.insertText(content, replacementRange: NSRange(location: match.range.location, length: match.range.length - 1))
                typingAttributes = nextTyping
                formatChanged?()
                return
            }
        }
        if let attributed = insertString as? NSAttributedString {
            super.insertText(HerdrNoteTextStyle.normalized(attributed, ink: ink), replacementRange: replacementRange)
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    override func didChangeText() {
        // Rich paste and native font commands cannot introduce foreign typography.
        if let storage = textStorage {
            let normalized = HerdrNoteTextStyle.normalized(storage, ink: ink)
            if !storage.isEqual(to: normalized) {
                storage.beginEditing()
                normalized.enumerateAttributes(in: NSRange(location: 0, length: normalized.length)) { values, range, _ in
                    storage.setAttributes(values, range: range)
                }
                storage.endEditing()
            }
        }
        typingAttributes = HerdrNoteTextStyle.attributes(typingAttributes, ink: ink)
        super.didChangeText()
        formatChanged?()
    }

    func isActive(_ format: HerdrNoteTextStyle.Format) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            return HerdrNoteTextStyle.contains(format, in: typingAttributes)
        }
        var enabled = true
        storage.enumerateAttributes(in: range) { values, _, _ in
            enabled = enabled && HerdrNoteTextStyle.contains(format, in: values)
        }
        return enabled
    }

    func toggle(_ format: HerdrNoteTextStyle.Format) {
        guard isEditable, !hasMarkedText() else { return }
        let enabled = !isActive(format)
        let range = selectedRange()
        if range.length == 0 {
            typingAttributes = HerdrNoteTextStyle.applying(format, enabled: enabled, to: typingAttributes, ink: ink)
        } else if let storage = textStorage {
            let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) { values, run, _ in
                replacement.setAttributes(HerdrNoteTextStyle.applying(format, enabled: enabled, to: values, ink: ink), range: run)
            }
            super.insertText(replacement, replacementRange: range)
            setSelectedRange(range)
        }
        window?.makeFirstResponder(self)
        formatChanged?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleFormattingKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleFormattingKey(event) { super.keyDown(with: event) }
    }

    private func handleFormattingKey(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable else { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let format: HerdrNoteTextStyle.Format = ["b": .bold, "i": .italic, "u": .underline][event.charactersIgnoringModifiers ?? ""] {
            toggle(format)
            return true
        }
        return false
    }

    @objc private func boldNote(_ sender: Any?) { toggle(.bold) }
    @objc private func italicNote(_ sender: Any?) { toggle(.italic) }
    @objc private func underlineNote(_ sender: Any?) { toggle(.underline) }
    @objc private func strikeNote(_ sender: Any?) { toggle(.strikethrough) }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) } else { onEscape?() }
    }

    override func changeFont(_ sender: Any?) {
        // Font-family and size commands are deliberately unavailable for notes.
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Cut", #selector(cut(_:))), ("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))), ("Select All", #selector(selectAll(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        for (title, action) in [("Bold", #selector(boldNote(_:))), ("Italic", #selector(italicNote(_:))), ("Underline", #selector(underlineNote(_:))), ("Strikethrough", #selector(strikeNote(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }
}
