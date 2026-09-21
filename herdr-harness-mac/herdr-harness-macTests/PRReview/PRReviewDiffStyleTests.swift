import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review diff style", .serialized)
struct PRReviewDiffStyleTests {
    // MARK: Shared palette

    @Test("Change colors resolve the production Git RGB values and opacities")
    func changeColorsMatchProductionGit() throws {
        try expect(HerdrDiffStyle.lineColor(for: "add"), red: 46, green: 160, blue: 67, alpha: 0.30)
        try expect(HerdrDiffStyle.gutterColor(for: "add"), red: 46, green: 160, blue: 67, alpha: 0.42)
        try expect(HerdrDiffStyle.emphasisColor(for: "add"), red: 46, green: 160, blue: 67, alpha: 0.55)
        try expect(HerdrDiffStyle.lineColor(for: "del"), red: 248, green: 81, blue: 73, alpha: 0.30)
        try expect(HerdrDiffStyle.gutterColor(for: "del"), red: 248, green: 81, blue: 73, alpha: 0.42)
        try expect(HerdrDiffStyle.emphasisColor(for: "del"), red: 248, green: 81, blue: 73, alpha: 0.55)
        #expect(HerdrDiffStyle.lineColor(for: "context") == nil)
        #expect(HerdrDiffStyle.gutterColor(for: "context") == nil)
        #expect(HerdrDiffStyle.emphasisColor(for: "context") == nil)
        #expect(HerdrDiffStyle.lineColor(for: "hunk") == nil)
    }

    // MARK: Intraline emphasis

    @Test("Adjacent replacements emphasize only the changed words")
    func emphasizesChangedWords() throws {
        let scalar = try #require(PRReviewIntralineDiff.emphasis(old: "let count = 1", new: "let count = 2"))
        #expect(scalar.old == [12..<13])
        #expect(scalar.new == [12..<13])

        let oldLine = "launch seed catalog sync"
        let newLine = "launch seed inventory sync"
        let words = try #require(PRReviewIntralineDiff.emphasis(old: oldLine, new: newLine))
        let catalog = (oldLine as NSString).range(of: "catalog")
        let inventory = (newLine as NSString).range(of: "inventory")
        #expect(words.old == [catalog.location..<NSMaxRange(catalog)])
        #expect(words.new == [inventory.location..<NSMaxRange(inventory)])
    }

    @Test("Emphasis ranges stay on UTF-16 boundaries for Unicode text")
    func emphasizesUnicodeRanges() throws {
        let old = "let status = \"😀\""
        let new = "let status = \"🌻\""
        let emphasis = try #require(PRReviewIntralineDiff.emphasis(old: old, new: new))
        let oldEmoji = (old as NSString).range(of: "😀")
        let newEmoji = (new as NSString).range(of: "🌻")
        #expect(oldEmoji.length == 2)
        #expect(emphasis.old == [oldEmoji.location..<NSMaxRange(oldEmoji)])
        #expect(emphasis.new == [newEmoji.location..<NSMaxRange(newEmoji)])

        let decomposedOld = "cafe\u{301} au lait"
        let decomposedNew = "cafe au lait"
        let decomposed = try #require(PRReviewIntralineDiff.emphasis(old: decomposedOld, new: decomposedNew))
        try expectValidRanges(decomposed.old, in: decomposedOld)
        try expectValidRanges(decomposed.new, in: decomposedNew)
    }

    @Test("Identical and whitespace-only changes fall back to row highlighting")
    func ignoresUnchangedText() {
        #expect(PRReviewIntralineDiff.emphasis(old: "let value = 1", new: "let value = 1") == nil)
        #expect(PRReviewIntralineDiff.emphasis(old: "let value = 1", new: "let  value = 1") == nil)
        #expect(PRReviewIntralineDiff.emphasis(old: "", new: "added") == nil)
        #expect(PRReviewIntralineDiff.emphasis(old: "removed", new: "") == nil)
    }

    @Test("Intraline emphasis is bounded for long and token-heavy lines")
    func boundsLargeLines() {
        let long = String(repeating: "a", count: PRReviewIntralineDiff.maximumUTF16LengthPerLine + 1)
        #expect(PRReviewIntralineDiff.emphasis(old: long, new: long + "b") == nil)

        let tokenHeavy = Array(repeating: "abcd", count: 400).joined(separator: " ")
        #expect((tokenHeavy as NSString).length <= PRReviewIntralineDiff.maximumUTF16LengthPerLine)
        let tokenHeavyChanged = tokenHeavy.replacingOccurrences(of: "abcd", with: "abce")
        #expect(PRReviewIntralineDiff.emphasis(old: tokenHeavy, new: tokenHeavyChanged) == nil)
    }

    @Test("Intraline results are deterministic across repeated calls")
    func intralineIsDeterministic() throws {
        let old = "let seed = oldValue + 1"
        let new = "let count = newValue - 2"
        let first = try #require(PRReviewIntralineDiff.emphasis(old: old, new: new))
        for _ in 0..<5 {
            #expect(PRReviewIntralineDiff.emphasis(old: old, new: new) == first)
        }
    }

    // MARK: Renderer ranges

    @Test("Rendered replacements attach emphasis at the changed UTF-16 ranges")
    func rendererAttachesEmphasisRanges() throws {
        let file = diffFile(lines: replacementLines())
        let rendered = PRReviewDiffRenderer.render(file: file)

        let delEntry = try #require(rendered.index.entries.first { $0.kind == "del" })
        let addEntry = try #require(rendered.index.entries.first { $0.kind == "add" })
        let contextEntry = try #require(rendered.index.entries.first { $0.kind == "context" })
        let hunkEntry = try #require(rendered.index.entries.first { $0.kind == "hunk" })

        let delWord = (file.hunks[0].lines[1].text as NSString).range(of: "oldValue")
        let addWord = (file.hunks[0].lines[2].text as NSString).range(of: "newValue")
        let delRange = NSRange(
            location: delEntry.utf16Offset + delEntry.gutterLength + 1 + delWord.location,
            length: delWord.length
        )
        let addRange = NSRange(
            location: addEntry.utf16Offset + addEntry.gutterLength + 1 + addWord.location,
            length: addWord.length
        )

        for location in delRange.location..<NSMaxRange(delRange) {
            #expect(rendered.text.attribute(.backgroundColor, at: location, effectiveRange: nil) != nil)
        }
        for location in addRange.location..<NSMaxRange(addRange) {
            #expect(rendered.text.attribute(.backgroundColor, at: location, effectiveRange: nil) != nil)
        }
        #expect(isSameColor(
            rendered.text.attribute(.backgroundColor, at: delRange.location, effectiveRange: nil),
            HerdrDiffStyle.emphasisColor(for: "del")
        ))
        #expect(isSameColor(
            rendered.text.attribute(.backgroundColor, at: addRange.location, effectiveRange: nil),
            HerdrDiffStyle.emphasisColor(for: "add")
        ))

        // Only the two changed words carry a background; gutters, prefixes,
        // hunk headers, and unchanged context do not.
        #expect(backgroundRanges(in: rendered.text).count == 2)
        #expect(rendered.text.attribute(.backgroundColor, at: delEntry.utf16Offset, effectiveRange: nil) == nil)
        #expect(rendered.text.attribute(
            .backgroundColor,
            at: delEntry.utf16Offset + delEntry.gutterLength,
            effectiveRange: nil
        ) == nil)
        #expect(rendered.text.attribute(
            .backgroundColor,
            at: contextEntry.utf16Offset + contextEntry.gutterLength + 1,
            effectiveRange: nil
        ) == nil)
        #expect(rendered.text.attribute(.backgroundColor, at: hunkEntry.utf16Offset, effectiveRange: nil) == nil)

        // Styling must not alter the source text or the before/after mapping.
        #expect(rendered.text.string.contains("-let seed = oldValue\n"))
        #expect(rendered.text.string.contains("+let seed = newValue\n"))
        #expect(delEntry.side == .before)
        #expect(delEntry.oldLine == 2)
        #expect(delEntry.newLine == nil)
        #expect(addEntry.side == .after)
        #expect(addEntry.newLine == 2)
        #expect(addEntry.oldLine == nil)
    }

    @Test("Unpaired and oversized replacement blocks keep ordinary row highlighting")
    func rendererSkipsUnpairedAndOversizedPairs() {
        let long = String(repeating: "let ", count: 500) + "seed"
        let cases = [
            diffFile(lines: [line("del", old: 2, new: nil, text: "let seed = oldValue")]),
            diffFile(lines: [line("add", old: nil, new: 2, text: "let seed = newValue")]),
            diffFile(lines: [
                line("del", old: 2, new: nil, text: long),
                line("add", old: nil, new: 2, text: long + "x"),
            ]),
        ]
        for file in cases {
            let rendered = PRReviewDiffRenderer.render(file: file)
            #expect(backgroundRanges(in: rendered.text).isEmpty)
            #expect(rendered.index.entries.contains { $0.kind == "add" || $0.kind == "del" })
        }
    }

    @Test("Unequal replacement blocks emphasize only the paired lines")
    func rendererPairsUnequalBlocks() throws {
        let file = diffFile(lines: [
            line("del", old: 2, new: nil, text: "let a = 1"),
            line("del", old: 3, new: nil, text: "let b = 2"),
            line("add", old: nil, new: 2, text: "let c = 3"),
        ])
        let rendered = PRReviewDiffRenderer.render(file: file)
        let delEntries = rendered.index.entries.filter { $0.kind == "del" }
        #expect(delEntries.count == 2)
        #expect(!backgroundRanges(in: rendered.text, within: entryRange(delEntries[0])).isEmpty)
        #expect(backgroundRanges(in: rendered.text, within: entryRange(delEntries[1])).isEmpty)

        let emphasizedLines = delEntries.compactMap { entry -> Int? in
            backgroundRanges(in: rendered.text, within: entryRange(entry)).isEmpty ? nil : entry.oldLine
        }
        #expect(emphasizedLines == [2])
    }

    @Test("Empty changed lines render rows without emphasis")
    func rendererHandlesEmptyChangedLines() {
        let file = diffFile(lines: [
            line("del", old: 2, new: nil, text: "let seed = oldValue"),
            line("add", old: nil, new: 2, text: ""),
        ])
        let rendered = PRReviewDiffRenderer.render(file: file)
        #expect(rendered.text.string.hasSuffix("+\n"))
        #expect(backgroundRanges(in: rendered.text).isEmpty)
        #expect(rendered.index.entries.contains { $0.kind == "add" && $0.length > 0 })
    }

    @Test("Deleted files and partial hunks render with the shared styling")
    func rendererHandlesDeletedFilesAndPartialHunks() {
        let deleted = diffFile(
            lines: [
                line("del", old: 2, new: nil, text: "let seed = oldValue"),
                line("del", old: 3, new: nil, text: "let count = 4"),
            ],
            status: "deleted",
            truncated: true
        )
        let deletedRender = PRReviewDiffRenderer.render(file: deleted)
        let sides = deletedRender.index.entries.compactMap(\.side)
        #expect(!sides.isEmpty)
        #expect(sides.allSatisfy { $0 == .before })
        #expect(backgroundRanges(in: deletedRender.text).isEmpty)
        #expect(deletedRender.text.string.contains("-let seed = oldValue\n"))

        let partial = diffFile(
            lines: [line("add", old: nil, new: 2, text: "let seed = newValue")],
            truncated: true
        )
        let partialRender = PRReviewDiffRenderer.render(file: partial)
        #expect(partialRender.text.string.contains("+let seed = newValue\n"))
        #expect(backgroundRanges(in: partialRender.text).isEmpty)
    }

    @Test("Font scaling resizes text without dropping emphasis")
    func rendererScalesWithFontPreference() throws {
        let file = diffFile(lines: replacementLines())
        let medium = PRReviewDiffRenderer.render(file: file, fontScale: .medium)
        let large = PRReviewDiffRenderer.render(file: file, fontScale: .xxLarge)
        let mediumSize = try #require(
            (medium.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        )
        let largeSize = try #require(
            (large.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        )
        #expect(largeSize > mediumSize)
        #expect(backgroundRanges(in: large.text).count == 2)
    }

    // MARK: Rendered backgrounds

    @Test("Rendered change rows, gutters, and emphasis use the shared palette")
    func rendersChangeBackgrounds() async throws {
        let render = try await mount(diffFile(lines: replacementLines()))
        defer { render.window.close() }

        let addEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "add" })
        let delEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "del" })
        let contextEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "context" })

        let graphite = (red: 32.0 / 255, green: 33.0 / 255, blue: 44.0 / 255)
        let addLine = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let delLine = composite(HerdrDiffStyle.deletion, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let addGutter = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.gutterOpacity, over: addLine)
        let delGutter = composite(HerdrDiffStyle.deletion, opacity: HerdrDiffStyle.gutterOpacity, over: delLine)
        let addEmphasis = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.emphasisOpacity, over: addLine)
        let delEmphasis = composite(HerdrDiffStyle.deletion, opacity: HerdrDiffStyle.emphasisOpacity, over: delLine)

        let rightEdge = render.textView.bounds.width - 3
        let addRow = try sample(CGPoint(x: rightEdge, y: fragmentRect(for: addEntry, in: render).midY), in: render)
        let delRow = try sample(CGPoint(x: rightEdge, y: fragmentRect(for: delEntry, in: render).midY), in: render)
        let contextRow = try sample(
            CGPoint(x: rightEdge, y: fragmentRect(for: contextEntry, in: render).midY),
            in: render
        )
        expect(addRow, matches: addLine, tolerance: 0.05)
        expect(delRow, matches: delLine, tolerance: 0.05)
        expect(contextRow, matches: graphite, tolerance: 0.05)

        let addGutterRect = gutterRect(for: addEntry, in: render)
        let addGutterPixel = try closestPixel(in: addGutterRect, to: addGutter, in: render)
        expect(addGutterPixel.color, matches: addGutter, tolerance: 0.05)
        let delGutterRect = gutterRect(for: delEntry, in: render)
        let delGutterPixel = try closestPixel(in: delGutterRect, to: delGutter, in: render)
        expect(delGutterPixel.color, matches: delGutter, tolerance: 0.05)

        let emphasisRanges = backgroundRanges(in: try #require(render.textView.textStorage))
        let addEmphasisRange = try #require(emphasisRanges.first {
            NSLocationInRange($0.location, entryRange(addEntry))
        })
        let delEmphasisRange = try #require(emphasisRanges.first {
            NSLocationInRange($0.location, entryRange(delEntry))
        })
        let addEmphasisPixel = try closestPixel(
            in: enclosingRect(for: addEmphasisRange, in: render),
            to: addEmphasis,
            in: render
        )
        expect(addEmphasisPixel.color, matches: addEmphasis, tolerance: 0.05)
        let delEmphasisPixel = try closestPixel(
            in: enclosingRect(for: delEmphasisRange, in: render),
            to: delEmphasis,
            in: render
        )
        expect(delEmphasisPixel.color, matches: delEmphasis, tolerance: 0.05)
    }

    @Test("Empty changed lines still paint their full change row")
    func rendersEmptyChangedLineRow() async throws {
        let file = diffFile(lines: [
            line("del", old: 2, new: nil, text: "let seed = oldValue"),
            line("add", old: nil, new: 2, text: ""),
        ])
        let render = try await mount(file)
        defer { render.window.close() }

        let addEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "add" })
        let graphite = (red: 32.0 / 255, green: 33.0 / 255, blue: 44.0 / 255)
        let addLine = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let addRow = try sample(
            CGPoint(x: render.textView.bounds.width - 3, y: fragmentRect(for: addEntry, in: render).midY),
            in: render
        )
        expect(addRow, matches: addLine, tolerance: 0.05)
        #expect(backgroundRanges(in: try #require(render.textView.textStorage)).isEmpty)
    }

    @Test("Deleted files paint their removal rows")
    func rendersDeletedFileChangeRow() async throws {
        let file = diffFile(
            lines: [line("del", old: 2, new: nil, text: "let seed = oldValue")],
            status: "deleted",
            truncated: true
        )
        let render = try await mount(file, size: CGSize(width: 420, height: 200))
        defer { render.window.close() }

        let delEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "del" })
        let graphite = (red: 32.0 / 255, green: 33.0 / 255, blue: 44.0 / 255)
        let delLine = composite(HerdrDiffStyle.deletion, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let delRow = try sample(
            CGPoint(x: render.textView.bounds.width - 3, y: fragmentRect(for: delEntry, in: render).midY),
            in: render
        )
        expect(delRow, matches: delLine, tolerance: 0.05)
    }

    @Test("Long lines keep their change row and emphasis backgrounds")
    func rendersLongLineBackgrounds() async throws {
        let longValue = String(repeating: "segment/", count: 30)
        let file = diffFile(lines: [
            line("del", old: 2, new: nil, text: "let path = \"\(longValue)old\""),
            line("add", old: nil, new: 2, text: "let path = \"\(longValue)new\""),
        ])
        let render = try await mount(file, size: CGSize(width: 420, height: 220))
        defer { render.window.close() }

        let addEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "add" })
        let graphite = (red: 32.0 / 255, green: 33.0 / 255, blue: 44.0 / 255)
        let addLine = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let addEmphasis = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.emphasisOpacity, over: addLine)

        #expect(render.textView.bounds.width > 420)
        let addRow = try sample(
            CGPoint(x: render.textView.bounds.width - 3, y: fragmentRect(for: addEntry, in: render).midY),
            in: render
        )
        expect(addRow, matches: addLine, tolerance: 0.05)

        let storage = try #require(render.textView.textStorage)
        let emphasisRange = try #require(backgroundRanges(in: storage).first {
            NSLocationInRange($0.location, entryRange(addEntry))
        })
        let emphasisPixel = try closestPixel(
            in: enclosingRect(for: emphasisRange, in: render),
            to: addEmphasis,
            in: render
        )
        expect(emphasisPixel.color, matches: addEmphasis, tolerance: 0.05)
    }

    @Test("Unicode replacements keep emphasis backgrounds on their exact range")
    func rendersUnicodeEmphasis() async throws {
        let file = diffFile(lines: [
            line("del", old: 2, new: nil, text: "let status = \"😀\""),
            line("add", old: nil, new: 2, text: "let status = \"🌻\""),
        ])
        let render = try await mount(file, size: CGSize(width: 420, height: 220))
        defer { render.window.close() }

        let addEntry = try #require(render.textView.lineIndex.entries.first { $0.kind == "add" })
        let graphite = (red: 32.0 / 255, green: 33.0 / 255, blue: 44.0 / 255)
        let addLine = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.lineOpacity, over: graphite)
        let addEmphasis = composite(HerdrDiffStyle.addition, opacity: HerdrDiffStyle.emphasisOpacity, over: addLine)

        let storage = try #require(render.textView.textStorage)
        let emphasisRange = try #require(backgroundRanges(in: storage).first {
            NSLocationInRange($0.location, entryRange(addEntry))
        })
        #expect(emphasisRange.length == 2)
        let emphasisPixel = try closestPixel(
            in: enclosingRect(for: emphasisRange, in: render),
            to: addEmphasis,
            in: render
        )
        expect(emphasisPixel.color, matches: addEmphasis, tolerance: 0.05)
    }

    // MARK: Fixtures

    private func diffFile(
        lines: [PRReviewDiffLine],
        status: String = "modified",
        truncated: Bool = false
    ) -> PRReviewDiffFile {
        PRReviewDiffFile(
            path: "Sources/Garden/Planting.swift",
            oldPath: nil,
            status: status,
            additions: lines.filter { $0.kind == "add" }.count,
            deletions: lines.filter { $0.kind == "del" }.count,
            binary: false,
            truncated: truncated,
            hunks: [
                PRReviewDiffHunk(
                    oldStart: 1,
                    oldLines: lines.filter { $0.kind != "add" }.count,
                    newStart: 1,
                    newLines: lines.filter { $0.kind != "del" }.count,
                    header: "@@ -1,4 +1,4 @@",
                    lines: lines
                )
            ]
        )
    }

    private func replacementLines() -> [PRReviewDiffLine] {
        [
            line("context", old: 1, new: 1, text: "import Foundation"),
            line("del", old: 2, new: nil, text: "let seed = oldValue"),
            line("add", old: nil, new: 2, text: "let seed = newValue"),
            line("context", old: 3, new: 3, text: "print(\"done\")"),
        ]
    }

    private func line(_ kind: String, old: Int?, new: Int?, text: String) -> PRReviewDiffLine {
        PRReviewDiffLine(kind: kind, oldNumber: old, newNumber: new, text: text)
    }

    // MARK: Color helpers

    private func expect(
        _ color: NSColor?,
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let resolved = try #require(color?.usingColorSpace(.sRGB), sourceLocation: sourceLocation)
        #expect(abs(Double(resolved.redComponent) - red / 255) < 0.002, sourceLocation: sourceLocation)
        #expect(abs(Double(resolved.greenComponent) - green / 255) < 0.002, sourceLocation: sourceLocation)
        #expect(abs(Double(resolved.blueComponent) - blue / 255) < 0.002, sourceLocation: sourceLocation)
        #expect(abs(Double(resolved.alphaComponent) - alpha) < 0.002, sourceLocation: sourceLocation)
    }

    private func expect(
        _ sample: (red: Double, green: Double, blue: Double),
        matches expected: (red: Double, green: Double, blue: Double),
        tolerance: Double = 0.02,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(sample.red - expected.red) < tolerance,
            "red \(sample.red) differs from \(expected.red)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(sample.green - expected.green) < tolerance,
            "green \(sample.green) differs from \(expected.green)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(sample.blue - expected.blue) < tolerance,
            "blue \(sample.blue) differs from \(expected.blue)",
            sourceLocation: sourceLocation
        )
    }

    private func composite(
        _ color: HerdrDiffStyle.ChangeColor,
        opacity: Double,
        over base: (red: Double, green: Double, blue: Double)
    ) -> (red: Double, green: Double, blue: Double) {
        (
            opacity * Double(color.red) / 255 + (1 - opacity) * base.red,
            opacity * Double(color.green) / 255 + (1 - opacity) * base.green,
            opacity * Double(color.blue) / 255 + (1 - opacity) * base.blue
        )
    }

    private func isSameColor(_ lhs: Any?, _ rhs: NSColor?) -> Bool {
        guard let lhs = lhs as? NSColor, let rhs,
              let left = lhs.usingColorSpace(.sRGB),
              let right = rhs.usingColorSpace(.sRGB)
        else { return false }
        return abs(left.redComponent - right.redComponent) < 0.002
            && abs(left.greenComponent - right.greenComponent) < 0.002
            && abs(left.blueComponent - right.blueComponent) < 0.002
            && abs(left.alphaComponent - right.alphaComponent) < 0.002
    }

    private func expectValidRanges(
        _ ranges: [Range<Int>],
        in text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let length = (text as NSString).length
        for range in ranges {
            let nsRange = NSRange(location: range.lowerBound, length: range.count)
            #expect(NSMaxRange(nsRange) <= length, sourceLocation: sourceLocation)
            #expect(!(text as NSString).substring(with: nsRange).isEmpty, sourceLocation: sourceLocation)
        }
    }

    private func backgroundRanges(in text: NSAttributedString, within range: NSRange? = nil) -> [NSRange] {
        var ranges: [NSRange] = []
        let scope = range ?? NSRange(location: 0, length: text.length)
        guard NSMaxRange(scope) <= text.length else { return [] }
        text.enumerateAttribute(.backgroundColor, in: scope) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    // MARK: Rendering helpers

    private struct DiffRender {
        let window: NSWindow
        let textView: PRReviewDiffTextView
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let bitmap: NSBitmapImageRep
        let scale: CGFloat
    }

    private func mount(
        _ file: PRReviewDiffFile,
        size: CGSize = CGSize(width: 820, height: 300)
    ) async throws -> DiffRender {
        let hosting = NSHostingView(rootView:
            PRReviewDiffText(file: file)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()

        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }

        let textView = try #require(descendants(hosting).compactMap { $0 as? PRReviewDiffTextView }.first)
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let scale: CGFloat = 2
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(ceil(textView.bounds.width * scale))),
            pixelsHigh: max(1, Int(ceil(textView.bounds.height * scale))),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = textView.bounds.size
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        return DiffRender(
            window: window,
            textView: textView,
            layoutManager: layoutManager,
            textContainer: textContainer,
            bitmap: bitmap,
            scale: scale
        )
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func entryRange(_ entry: PRReviewLineIndex.Entry) -> NSRange {
        NSRange(location: entry.utf16Offset, length: entry.length)
    }

    private func fragmentRect(for entry: PRReviewLineIndex.Entry, in render: DiffRender) -> NSRect {
        let glyphs = render.layoutManager.glyphRange(forCharacterRange: entryRange(entry), actualCharacterRange: nil)
        let used = render.layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return used.offsetBy(
            dx: render.textView.textContainerOrigin.x,
            dy: render.textView.textContainerOrigin.y
        )
    }

    private func gutterRect(for entry: PRReviewLineIndex.Entry, in render: DiffRender) -> NSRect {
        enclosingRect(
            for: NSRange(location: entry.utf16Offset, length: entry.gutterLength),
            in: render
        )
    }

    private func enclosingRect(for range: NSRange, in render: DiffRender) -> NSRect {
        let glyphs = render.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var union = NSRect.null
        render.layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: render.textContainer
        ) { rect, _ in
            union = union.union(rect)
        }
        return union.offsetBy(
            dx: render.textView.textContainerOrigin.x,
            dy: render.textView.textContainerOrigin.y
        )
    }

    private func sample(
        _ point: CGPoint,
        in render: DiffRender
    ) throws -> (red: Double, green: Double, blue: Double) {
        let bounds = render.textView.bounds
        let viewY = render.textView.isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        let pixelX = Int(((point.x - bounds.minX) * render.scale).rounded())
        let pixelY = Int((viewY * render.scale).rounded())
        return try resolve(pixelX: pixelX, pixelY: pixelY, in: render)
    }

    private func closestPixel(
        in rect: NSRect,
        to expected: (red: Double, green: Double, blue: Double),
        in render: DiffRender
    ) throws -> (color: (red: Double, green: Double, blue: Double), distance: Double) {
        let bounds = render.textView.bounds
        let top = render.textView.isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
        let bottom = render.textView.isFlipped ? rect.maxY - bounds.minY : bounds.maxY - rect.minY
        let minX = max(0, Int(((rect.minX - bounds.minX) * render.scale).rounded(.down)))
        let maxX = min(render.bitmap.pixelsWide - 1, Int(((rect.maxX - bounds.minX) * render.scale).rounded(.up)))
        let minY = max(0, Int((top * render.scale).rounded(.down)))
        let maxY = min(render.bitmap.pixelsHigh - 1, Int((bottom * render.scale).rounded(.up)))
        guard minX <= maxX, minY <= maxY else {
            throw DiffSampleError.emptyRect
        }

        var best: ((red: Double, green: Double, blue: Double), Double)?
        for y in minY...maxY {
            for x in minX...maxX {
                guard let color = render.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let sample = (
                    red: Double(color.redComponent),
                    green: Double(color.greenComponent),
                    blue: Double(color.blueComponent)
                )
                let distance = channelDistance(sample, expected)
                if best == nil || distance < best!.1 {
                    best = (sample, distance)
                }
            }
        }
        return try #require(best)
    }

    private func resolve(
        pixelX: Int,
        pixelY: Int,
        in render: DiffRender
    ) throws -> (red: Double, green: Double, blue: Double) {
        let x = min(max(pixelX, 0), render.bitmap.pixelsWide - 1)
        let y = min(max(pixelY, 0), render.bitmap.pixelsHigh - 1)
        let color = try #require(render.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent)
        )
    }

    private func channelDistance(
        _ lhs: (red: Double, green: Double, blue: Double),
        _ rhs: (red: Double, green: Double, blue: Double)
    ) -> Double {
        max(
            abs(lhs.red - rhs.red),
            abs(lhs.green - rhs.green),
            abs(lhs.blue - rhs.blue)
        )
    }

    private enum DiffSampleError: Error {
        case emptyRect
    }
}
