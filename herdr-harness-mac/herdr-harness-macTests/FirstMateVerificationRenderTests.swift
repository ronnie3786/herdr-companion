import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Renders the production verification summary and checks the actual pixels for
/// each scoped verdict. The gate rows are deliberately outcome-free in the
/// distinctness cases so the only tone colors on screen come from the verdict
/// itself; the long-identifier case proves the summary grows to wrap instead of
/// truncating a package-qualified suite name.
@Suite("First Mate verification summary renders", .serialized)
@MainActor
struct FirstMateVerificationRenderTests {
    @Test("Each scoped verdict renders its own tone in both appearances",
          arguments: [ColorScheme.light, .dark])
    func toneRenders(scheme: ColorScheme) async throws {
        let cases: [(name: String, verification: FirstMateVerification, tone: FirstMateVerificationTone)] = [
            ("verified", Self.verifiedFixture(), .positive),
            ("partial", Self.partialFixture(), .caution),
            ("failed", Self.failedFixture(), .negative),
        ]
        for entry in cases {
            let render = try await HerdrRenderHarness.render(
                "first-mate-verification-\(entry.name)-\(scheme == .light ? "light" : "dark").png",
                size: CGSize(width: 560, height: 520)
            ) {
                FirstMateVerificationSummaryView(verification: entry.verification)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(FirstMatePalette(scheme: scheme).background)
                    .environment(\.colorScheme, scheme)
            }
            render.expectSubstantial(minimumBytes: 2_048)
            let bitmap = try bitmap(of: render)
            let expected = try rgb(FirstMateVerificationPalette.color(for: entry.tone, scheme: scheme))
            #expect(
                pixelCount(in: bitmap, matching: expected) >= 12,
                "\(entry.name) in \(scheme) did not render its \(entry.tone) tone"
            )
            for other in cases where other.name != entry.name {
                let otherColor = try rgb(FirstMateVerificationPalette.color(for: other.tone, scheme: scheme))
                #expect(
                    pixelCount(in: bitmap, matching: otherColor) == 0,
                    "\(entry.name) in \(scheme) rendered \(other.name)'s tone"
                )
            }
        }
    }

    @Test("A last-reported verdict marks cached evidence in both appearances")
    func lastReportedRenders() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let render = try await HerdrRenderHarness.render(
                "first-mate-verification-last-reported-\(scheme == .light ? "light" : "dark").png",
                size: CGSize(width: 560, height: 600)
            ) {
                FirstMateVerificationSummaryView(verification: Self.verifiedFixture(), isLastReported: true)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(FirstMatePalette(scheme: scheme).background)
                    .environment(\.colorScheme, scheme)
            }
            render.expectSubstantial(minimumBytes: 2_048)
            let bitmap = try bitmap(of: render)
            let caution = try rgb(FirstMateVerificationPalette.color(for: .caution, scheme: scheme))
            #expect(pixelCount(in: bitmap, matching: caution) >= 12)
        }
    }

    @Test("Long package-qualified suite identifiers wrap without dropping entries")
    func longIdentifiers() async throws {
        let longPackage = "packages/" + String(repeating: "sample-really-long-segment/", count: 5) + "core"
        let longSuite = String(repeating: "VeryLongSuiteName", count: 6)
        let missing = FirstMateVerificationSuite(
            label: "\(longPackage)/\(longSuite) (debug)",
            package: longPackage,
            suite: longSuite,
            configuration: "debug",
            reason: "never run"
        )
        let verification = FirstMateVerification(
            status: .partiallyVerified,
            missingSuites: [missing],
            evidencePresent: true
        )
        let presentation = FirstMateVerificationPresentation(verification: verification)
        #expect(presentation.accessibilitySummary.contains(longSuite))
        #expect(presentation.accessibilitySummary.contains("(debug)"))

        let compact = NSHostingView(
            rootView: FirstMateVerificationSummaryView(
                verification: FirstMateVerification(status: .verified, evidencePresent: true)
            )
            .frame(width: 420)
        )
        compact.layoutSubtreeIfNeeded()
        for scheme in [ColorScheme.light, .dark] {
            let long = NSHostingView(
                rootView: FirstMateVerificationSummaryView(verification: verification)
                    .frame(width: 420)
                    .environment(\.colorScheme, scheme)
            )
            long.layoutSubtreeIfNeeded()
            #expect(long.fittingSize.height > compact.fittingSize.height)

            let render = try await HerdrRenderHarness.render(
                "first-mate-verification-long-\(scheme == .light ? "light" : "dark").png",
                size: CGSize(width: 560, height: 400)
            ) {
                FirstMateVerificationSummaryView(verification: verification)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(FirstMatePalette(scheme: scheme).background)
                    .environment(\.colorScheme, scheme)
            }
            render.expectSubstantial(minimumBytes: 2_048)
        }
    }

    // MARK: - Fixtures

    private static func suite(_ label: String, outcome: String? = nil) -> FirstMateVerificationSuite {
        FirstMateVerificationSuite(label: label, package: label, suite: label, outcome: outcome)
    }

    /// Only positive pixels: the status line and its passing gate rows.
    private static func verifiedFixture() -> FirstMateVerification {
        FirstMateVerification(
            status: .verified,
            featureRevision: 4,
            sourceRevisions: ["demo-0123456789abcdef"],
            gateSet: [suite("packages/sample-core/One", outcome: "passed")],
            evidencePresent: true,
            computedAt: "2026-09-24T12:00:00Z"
        )
    }

    /// Only caution pixels: the status line and its missing-suite heading. No
    /// gate rows means no passing green and no failing red.
    private static func partialFixture() -> FirstMateVerification {
        FirstMateVerification(
            status: .partiallyVerified,
            featureRevision: 4,
            sourceRevisions: ["demo-0123456789abcdef"],
            missingSuites: [FirstMateVerificationSuite(label: "packages/sample-core/Missing", reason: "never run")],
            evidencePresent: true,
            computedAt: "2026-09-24T12:00:00Z"
        )
    }

    /// Only negative pixels: the status line and its failing gate row.
    private static func failedFixture() -> FirstMateVerification {
        FirstMateVerification(
            status: .failed,
            featureRevision: 4,
            sourceRevisions: ["demo-0123456789abcdef"],
            gateSet: [suite("packages/sample-core/Broken", outcome: "failed")],
            failingSuites: [suite("packages/sample-core/Broken", outcome: "failed")],
            evidencePresent: true,
            computedAt: "2026-09-24T12:00:00Z"
        )
    }
}

// MARK: - Pixel helpers

private struct VerificationRenderRGB: Equatable, CustomStringConvertible {
    let red: Double
    let green: Double
    let blue: Double

    var description: String {
        String(format: "rgb(%.3f, %.3f, %.3f)", red, green, blue)
    }
}

private func rgb(_ color: Color) throws -> VerificationRenderRGB {
    let converted = try #require(NSColor(color).usingColorSpace(.sRGB))
    return VerificationRenderRGB(
        red: converted.redComponent,
        green: converted.greenComponent,
        blue: converted.blueComponent
    )
}

private func bitmap(of render: HerdrRenderHarness.RenderResult) throws -> NSBitmapImageRep {
    try #require(NSBitmapImageRep(data: Data(contentsOf: render.url)))
}

private func pixelCount(
    in bitmap: NSBitmapImageRep,
    matching target: VerificationRenderRGB,
    tolerance: Double = 0.12
) -> Int {
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
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
