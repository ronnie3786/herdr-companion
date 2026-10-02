import UIKit

/// The iOS editor uses the same style and Markdown rules as Mac. Explicit
/// rich replacements participate in native Undo, including formatting-only edits.
final class RemoteNoteTextView: UITextView {
    var ink = UIColor.black
    var onTextChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    func normalizeTypography() {
        let normalized = HerdrNoteTextStyle.normalized(textStorage, ink: ink)
        if !textStorage.isEqual(to: normalized) {
            textStorage.beginEditing()
            normalized.enumerateAttributes(in: NSRange(location: 0, length: normalized.length)) { values, range, _ in
                textStorage.setAttributes(values, range: range)
            }
            textStorage.endEditing()
        }
        typingAttributes = HerdrNoteTextStyle.attributes(typingAttributes, ink: ink)
    }

    func isActive(_ format: HerdrNoteTextStyle.Format) -> Bool {
        guard selectedRange.length > 0 else { return HerdrNoteTextStyle.contains(format, in: typingAttributes) }
        var enabled = true
        textStorage.enumerateAttributes(in: selectedRange) { values, _, _ in
            enabled = enabled && HerdrNoteTextStyle.contains(format, in: values)
        }
        return enabled
    }

    func toggle(_ format: HerdrNoteTextStyle.Format) {
        guard isEditable, markedTextRange == nil else { return }
        let enabled = !isActive(format)
        let range = selectedRange
        if range.length == 0 {
            typingAttributes = HerdrNoteTextStyle.applying(format, enabled: enabled, to: typingAttributes, ink: ink)
        } else {
            let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
            replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) { values, run, _ in
                replacement.setAttributes(HerdrNoteTextStyle.applying(format, enabled: enabled, to: values, ink: ink), range: run)
            }
            replaceRichText(in: range, with: replacement, selection: range, nextTyping: typingAttributes)
        }
        becomeFirstResponder()
        onSelectionChange?()
    }

    func convertMarkdown(in range: NSRange, replacement: String) -> Bool {
        guard isEditable, markedTextRange == nil, range.length == 0,
              ["*", "_", "~"].contains(replacement), range.location <= textStorage.length else { return false }
        let prefix = (textStorage.string as NSString).substring(to: range.location) + replacement
        guard let match = HerdrNoteTextStyle.markdownMatch(in: prefix) else { return false }
        let content = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: match.contentRange))
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { values, run, _ in
            content.setAttributes(HerdrNoteTextStyle.applying(match.format, enabled: true, to: values, ink: ink), range: run)
        }
        replaceRichText(in: NSRange(location: match.range.location, length: match.range.length - 1), with: content,
                        selection: NSRange(location: match.range.location + content.length, length: 0), nextTyping: typingAttributes)
        return true
    }

    private func replaceRichText(in range: NSRange, with replacement: NSAttributedString, selection: NSRange, nextTyping: [NSAttributedString.Key: Any]) {
        let updated = NSMutableAttributedString(attributedString: textStorage)
        updated.replaceCharacters(in: range, with: replacement)
        restore(updated, selection: selection, typing: nextTyping)
    }

    private func restore(_ value: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any]) {
        let previous = NSAttributedString(attributedString: textStorage)
        let previousSelection = selectedRange
        let previousTyping = typingAttributes
        undoManager?.registerUndo(withTarget: self) { view in
            view.restore(previous, selection: previousSelection, typing: previousTyping)
        }
        textStorage.setAttributedString(value)
        selectedRange = selection
        typingAttributes = HerdrNoteTextStyle.attributes(typing, ink: ink)
        scrollRangeToVisible(selection)
        onTextChange?()
        onSelectionChange?()
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(title: "Bold", action: #selector(boldNote), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italic", action: #selector(italicNote), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Underline", action: #selector(underlineNote), input: "u", modifierFlags: .command)
        ]
    }

    @objc private func boldNote() { toggle(.bold) }
    @objc private func italicNote() { toggle(.italic) }
    @objc private func underlineNote() { toggle(.underline) }
}
