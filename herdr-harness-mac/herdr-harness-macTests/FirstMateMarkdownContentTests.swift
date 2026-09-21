import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate markdown content")
@MainActor
struct FirstMateMarkdownContentTests {
    @Test("Assistant markdown and literal user text host at large sizes in both appearances")
    func hostsInBothAppearances() {
        let source = """
        # Review

        A **readable** result with `inline code`.

        - First item
        - Second item

        | Check | State |
        | --- | --- |
        | Synthetic | Complete |
        """
        let assistant = FirstMateMessage(
            id: "synthetic-assistant",
            featureID: "synthetic-feature",
            role: "assistant",
            text: source,
            status: "delivered",
            createdAt: "2026-01-01T00:00:00Z"
        )
        let user = FirstMateMessage(
            id: "synthetic-user",
            featureID: "synthetic-feature",
            role: "user",
            text: "# Keep this literal",
            status: "queued",
            createdAt: "2026-01-01T00:00:01Z"
        )

        for scheme in [ColorScheme.light, .dark] {
            let hosting = NSHostingView(
                rootView: VStack {
                    FirstMateMessageView(message: assistant)
                    FirstMateMessageView(message: user)
                }
                    .environment(\.colorScheme, scheme)
                    .environment(\.herdrFontScale, .xxxLarge)
                    .frame(width: 440)
            )
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0)
            #expect(hosting.fittingSize.height > 150)
        }
    }

    @Test("First Mate prose has readable contrast in both appearances")
    func paletteContrast() throws {
        for scheme in [ColorScheme.light, .dark] {
            let palette = FirstMatePalette(scheme: scheme)
            #expect(try contrast(palette.text, palette.background) >= 4.5)
            #expect(try contrast(palette.text, palette.surface) >= 4.5)
        }
    }

    private func contrast(_ first: Color, _ second: Color) throws -> Double {
        let a = try luminance(first)
        let b = try luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: Color) throws -> Double {
        let rgb = try #require(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
