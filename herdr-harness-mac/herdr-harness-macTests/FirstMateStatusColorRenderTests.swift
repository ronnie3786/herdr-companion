import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Renders the production First Mate badge and Dashboard pill and asserts the
/// actual foreground pixels, then places the badges beside synthetic agent
/// session bubbles so the shared palette is verified on screen rather than
/// only in color values.
@Suite("First Mate status color renders", .serialized)
@MainActor
struct FirstMateStatusColorRenderTests {
    private static let requestedStatuses = ["blocked", "awaiting_direction", "running"]

    @Test("A production badge renders the mapped foreground on both First Mate surfaces",
          arguments: [HerdrFontScale.medium, .xxxLarge])
    func badgeForegrounds(scale: HerdrFontScale) async throws {
        for scheme in [ColorScheme.dark, .light] {
            for status in Self.requestedStatuses {
                let expected = try rgb(try #require(FirstMateStatusColors.color(for: status, scheme: scheme)))
                let render = try await HerdrRenderHarness.render(
                    "first-mate-status-\(status)-\(scheme == .light ? "light" : "dark")-\(scale.label).png",
                    size: CGSize(width: 240, height: 64)
                ) {
                    FirstMateStatusLabel(status: status)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(FirstMatePalette(scheme: scheme).surface)
                        .environment(\.herdrFontScale, scale)
                        // The harness defaults to dark; the badge's light
                        // appearance must be requested on the child itself.
                        .environment(\.colorScheme, scheme)
                }
                render.expectSubstantial(minimumBytes: 1_024)
                let bitmap = try bitmap(of: render)
                #expect(
                    pixelCount(in: bitmap, matching: expected) >= 12,
                    "\(status) in \(scheme) at \(scale.label) did not render \(expected) foreground pixels"
                )
                // The positive light-color match above proves the child
                // colorScheme override took effect: the dark HUD tokens could
                // never satisfy it.
                // The other two requested colors must not appear, and the
                // faint 9% wash must stay outside the tolerance.
                for other in Self.requestedStatuses where other != status {
                    let otherColor = try rgb(try #require(FirstMateStatusColors.color(for: other, scheme: scheme)))
                    #expect(
                        pixelCount(in: bitmap, matching: otherColor) == 0,
                        "\(status) in \(scheme) at \(scale.label) rendered \(other)'s color"
                    )
                }
            }
        }
    }

    @Test("A Dashboard pill renders the mapped foreground and no longer shows working as green")
    func pillForegrounds() async throws {
        for status in Self.requestedStatuses {
            let expected = try rgb(try #require(FirstMateStatusColors.color(for: status, scheme: .dark)))
            let render = try await HerdrRenderHarness.render(
                "first-mate-status-pill-\(status).png",
                size: CGSize(width: 240, height: 64)
            ) {
                DashboardStatusPill(status: status)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(HerdrTheme.elevated)
            }
            render.expectSubstantial(minimumBytes: 1_024)
            let bitmap = try bitmap(of: render)
            #expect(
                pixelCount(in: bitmap, matching: expected) >= 12,
                "the \(status) pill did not render \(expected) foreground pixels"
            )
            for other in Self.requestedStatuses where other != status {
                let otherColor = try rgb(try #require(FirstMateStatusColors.color(for: other, scheme: .dark)))
                #expect(
                    pixelCount(in: bitmap, matching: otherColor) == 0,
                    "the \(status) pill rendered \(other)'s color"
                )
            }
        }
    }

    @Test("Parked-turn and blocked-turn pills keep the mapped colors")
    func pillAwaitingTurnPrecedence() async throws {
        let signal = try rgb(HerdrTheme.signal)
        let alert = try rgb(HerdrTheme.alert)

        let yourTurn = try await HerdrRenderHarness.render(
            "first-mate-status-pill-your-turn.png",
            size: CGSize(width: 240, height: 64)
        ) {
            DashboardStatusPill(status: "running", awaitingTurn: true)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(HerdrTheme.elevated)
        }
        yourTurn.expectSubstantial(minimumBytes: 1_024)
        let yourTurnBitmap = try bitmap(of: yourTurn)
        #expect(pixelCount(in: yourTurnBitmap, matching: signal) >= 12)
        #expect(pixelCount(in: yourTurnBitmap, matching: alert) == 0)

        let contradictory = try await HerdrRenderHarness.render(
            "first-mate-status-pill-blocked-turn.png",
            size: CGSize(width: 240, height: 64)
        ) {
            DashboardStatusPill(status: "blocked", awaitingTurn: true)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(HerdrTheme.elevated)
        }
        contradictory.expectSubstantial(minimumBytes: 1_024)
        let contradictoryBitmap = try bitmap(of: contradictory)
        #expect(pixelCount(in: contradictoryBitmap, matching: alert) >= 12)
        #expect(pixelCount(in: contradictoryBitmap, matching: signal) == 0)
    }

    @Test("First Mate badges beside synthetic HUD session bubbles share the dark palette")
    func badgesBesideHudBubbles() async throws {
        let firstMateStatuses = Self.requestedStatuses
        let hudStatuses: [(String, AgentStatus)] = [
            ("blocked", .blocked),
            ("awaiting_direction", .done),
            ("running", .working),
        ]
        let render = try await HerdrRenderHarness.render(
            "first-mate-status-beside-hud-bubbles.png",
            size: CGSize(width: 660, height: 300)
        ) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(firstMateStatuses, id: \.self) { status in
                        FirstMateStatusLabel(status: status)
                    }
                }
                .frame(width: 300, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hudStatuses, id: \.0) { pair in
                        HerdrHudSessionBubbleLabel(
                            chip: HerdrHudSessionChips.Chip(
                                id: "synthetic-\(pair.1.rawValue)",
                                title: "Synthetic \(pair.1.rawValue) session",
                                status: pair.1,
                                isMuted: false,
                                since: nil
                            ),
                            metadata: HerdrHudSessionMetadata()
                        )
                    }
                }
                .frame(width: 220, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(HerdrTheme.ink)
        }
        render.expectSubstantial(minimumBytes: 2_048)
        let bitmap = try bitmap(of: render)
        let left = 0..<(bitmap.pixelsWide / 2)
        let right = (bitmap.pixelsWide / 2)..<bitmap.pixelsWide

        // Both presentations must paint the same HUD tokens for blocked,
        // waiting/done, and working.
        let expectations: [(String, Color)] = [
            ("blocked", HerdrTheme.alert),
            ("awaiting_direction", HerdrTheme.signal),
            ("running", HerdrTheme.working),
        ]
        for (name, color) in expectations {
            let target = try rgb(color)
            #expect(
                pixelCount(in: bitmap, columns: left, matching: target) >= 12,
                "the First Mate \(name) badge did not render \(target) on the left"
            )
            #expect(
                pixelCount(in: bitmap, columns: right, matching: target) >= 12,
                "the HUD \(name) bubble did not render \(target) on the right"
            )
        }
    }
}

// MARK: - Pixel helpers

private struct RenderRGB: Equatable, CustomStringConvertible {
    let red: Double
    let green: Double
    let blue: Double

    var description: String {
        String(format: "rgb(%.3f, %.3f, %.3f)", red, green, blue)
    }
}

private func rgb(_ color: Color) throws -> RenderRGB {
    let converted = try #require(NSColor(color).usingColorSpace(.sRGB))
    return RenderRGB(
        red: converted.redComponent,
        green: converted.greenComponent,
        blue: converted.blueComponent
    )
}

private func bitmap(of render: HerdrRenderHarness.RenderResult) throws -> NSBitmapImageRep {
    try #require(NSBitmapImageRep(data: Data(contentsOf: render.url)))
}

/// Counts pixels close to `target` in each channel. The 0.12 tolerance admits
/// anti-aliased cores but still excludes the badge's ~0.09–0.12 color wash and
/// each other requested hue.
private func pixelCount(
    in bitmap: NSBitmapImageRep,
    columns: Range<Int>? = nil,
    matching target: RenderRGB,
    tolerance: Double = 0.12
) -> Int {
    let range = columns ?? 0..<bitmap.pixelsWide
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in range {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if abs(color.redComponent - target.red) <= tolerance,
               abs(color.greenComponent - target.green) <= tolerance,
               abs(color.blueComponent - target.blue) <= tolerance {
                count += 1
            }
        }
    }
    return count
}
