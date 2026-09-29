import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

@MainActor
final class HerdrThemeTypographyRenderTests: XCTestCase {
    func testUIKitHostedMarkdownAndMetricFontsRespectFirstMateCap() async throws {
        let harness = IOSNativeRenderHarness()
        for width: CGFloat in [320, 402] {
            for role in HerdrProse.Role.allCases {
                let capped = await harness.render(
                    ThemeTypographyFixture(role: role).herdrFirstMateChrome(), width: width, dynamicType: .xxxLarge
                )
                let requested = await harness.render(
                    ThemeTypographyFixture(role: role).herdrFirstMateChrome(), width: width, dynamicType: .accessibility3
                )
                XCTAssertTrue(capped.drewHierarchy && requested.drewHierarchy)
                // Both UIKit hosts really request the corresponding size, not
                // just the SwiftUI environment. Test the actual drawn Markdown.
                XCTAssertEqual(requested.element(identifier: "effective-size")?.label, "xxxLarge")
                XCTAssertEqual(requested.fittingSize, capped.fittingSize)
                XCTAssertEqual(requested.measurements, capped.measurements)
                XCTAssertEqual(try ThemeRaster(requested.image).sha256, try ThemeRaster(capped.image).sha256)
                // Semantic Font.scaled(by:) and UIFontMetrics have different
                // rounding/curves. Each must match its own explicit-cap output
                // above, not the other's absolute point size. Markdown and text
                // selection must not introduce an extra UIKit scaling pass.
                for (rendered, reference) in [("prose", "plain-prose"), ("selectable-metrics", "metrics")] {
                    let actual = try XCTUnwrap(requested.element(identifier: rendered))
                    let expected = try XCTUnwrap(requested.element(identifier: reference))
                    XCTAssertEqual(actual.frame.height, expected.frame.height, accuracy: 1, "\(role)")
                    XCTAssertEqual(actual.frame.width, expected.frame.width, accuracy: 1, "\(role)")
                }
            }
        }
    }

    func testCapStillScalesAndDoesNotChangeLegacyTypography() async {
        let harness = IOSNativeRenderHarness()
        let normal = await harness.render(
            ThemeTypographyFixture(role: .bubble).herdrFirstMateChrome(), width: 320, dynamicType: .defaultSize
        )
        let capped = await harness.render(
            ThemeTypographyFixture(role: .bubble).herdrFirstMateChrome(), width: 320, dynamicType: .accessibility3
        )
        let legacy = await harness.render(
            ThemeTypographyFixture(role: .bubble), width: 320, dynamicType: .accessibility3
        )
        XCTAssertTrue(normal.drewHierarchy && capped.drewHierarchy && legacy.drewHierarchy)
        XCTAssertEqual(normal.element(identifier: "effective-size")?.label, "large")
        XCTAssertEqual(legacy.element(identifier: "effective-size")?.label, "accessibility3")
        XCTAssertGreaterThan(capped.fittingSize.height, normal.fittingSize.height)
        XCTAssertGreaterThan(legacy.fittingSize.height, capped.fittingSize.height)
    }

    func testCappingScaleKeepsTheEntireLongMessage() async throws {
        let harness = IOSNativeRenderHarness()
        for width: CGFloat in [320, 402] {
            let capped = await harness.render(
                ThemeLongMessageFixture().herdrFirstMateChrome(), width: width, dynamicType: .xxxLarge
            )
            let requested = await harness.render(
                ThemeLongMessageFixture().herdrFirstMateChrome(), width: width, dynamicType: .accessibility3
            )
            XCTAssertTrue(capped.drewHierarchy && requested.drewHierarchy)
            XCTAssertEqual(requested.measurements, capped.measurements)
            XCTAssertEqual(try ThemeRaster(requested.image).sha256, try ThemeRaster(capped.image).sha256)
            let message = try XCTUnwrap(requested.element(identifier: "long-message"))
            XCTAssertGreaterThan(message.frame.height, 500, "All 24 lines must lay out, not ellipsize")
            XCTAssertEqual(message.label, ThemeLongMessageFixture.message)
            let tail = try XCTUnwrap(requested.element(identifier: "message-end"))
            XCTAssertGreaterThanOrEqual(tail.frame.minY, message.frame.maxY)
            XCTAssertLessThanOrEqual(tail.frame.maxY, requested.bounds.maxY)
        }
    }
}

private struct ThemeTypographyFixture: View {
    let role: HerdrProse.Role
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.fontResolutionContext) private var fontContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effective text size")
                .composerLayoutMeasurement(id: "effective-size", label: String(describing: dynamicType))
            PiMarkdownText("Full text.", font: HerdrProse.font(role))
                .fixedSize()
                .composerLayoutMeasurement(id: "prose", label: String(describing: prosePointSize))
            Text("Full text.").font(HerdrProse.font(role)).fixedSize()
                .composerLayoutMeasurement(id: "plain-prose")
            metricText.fixedSize()
                .composerLayoutMeasurement(id: "metrics", label: String(describing: metricPointSize))
            metricText.textSelection(.enabled).fixedSize()
                .composerLayoutMeasurement(id: "selectable-metrics")
            PiMarkdownText("**Bold**, _italic_, and `code`.", font: HerdrProse.font(role),
                           inlineCodeFont: HerdrProse.inlineCodeFont(role),
                           inlineCodeColor: HerdrProse.inlineCodeColor)
                .fixedSize(horizontal: false, vertical: true)
                .composerLayoutMeasurement(id: "markdown")
        }
        .padding(12)
    }

    private var prosePointSize: CGFloat { HerdrProse.font(role).resolve(in: fontContext).pointSize }
    private var metricPointSize: CGFloat {
        HerdrFont.scaledSize(role.baseSize, relativeTo: role.textStyle, dynamicType: dynamicType)
    }

    private var metricText: some View {
        var font = Font.system(size: metricPointSize, weight: role.weight)
        if role.isItalic { font = font.italic() }
        return Text("Full text.").font(font)
    }
}

private struct ThemeLongMessageFixture: View {
    static let message = (1...24).map { "Message line \($0) is complete." }.joined(separator: "\n")
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PiMarkdownText(Self.message, font: HerdrProse.font(.bubble))
                .lineSpacing(HerdrProse.lineSpacing(.bubble))
                .fixedSize(horizontal: false, vertical: true)
                .composerLayoutMeasurement(id: "long-message", label: Self.message)
            Text("End of the complete sample message.")
                .composerLayoutMeasurement(id: "message-end")
        }
        .padding(12)
    }
}
