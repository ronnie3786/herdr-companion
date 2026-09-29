import SwiftUI
import XCTest
@testable import herdr_harness_ios

@MainActor
final class IOSThemeDuskRenderTests: XCTestCase {
    func testDuskSampleAndAccessibility3() async throws {
        for (width, size, name) in [
            (CGFloat(390), IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, "theme-dusk-sample"),
            (CGFloat(402), .defaultSize, "theme-dusk-sample-402"),
            (CGFloat(402), .accessibility3, "theme-dusk-sample-accessibility3"),
            (CGFloat(320), .accessibility3, "theme-dusk-sample-320-capped"),
        ] {
            let render = await IOSNativeRenderHarness().render(
                HerdrThemeSampleContent()
                    .background(alignment: .top) {
                        ZStack(alignment: .top) {
                            HerdrGlassBackground(level: HerdrTheme.Glass.pane)
                            HerdrHazeBand()
                        }
                    }
                    .herdrFirstMateChrome(),
                width: width, dynamicType: size, background: .dusk
            )
            XCTAssertTrue(render.drewHierarchy)
            XCTAssertEqual(render.bounds.width, width)
            XCTAssertGreaterThan(render.fittingSize.height, 300)
            XCTAssertLessThan(render.fittingSize.height, 3_000)
            for id in ["theme-sample-field", "theme-sample-send", "theme-sample-readout"] {
                let control = try XCTUnwrap(render.element(identifier: id), render.measurementDiagnostics)
                XCTAssertGreaterThanOrEqual(control.frame.width, 44 - 0.001)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44 - 0.001)
                XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
                XCTAssertLessThanOrEqual(control.frame.maxX, width)
                XCTAssertLessThanOrEqual(control.frame.maxY, render.bounds.maxY)
            }
            let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
                             ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"]
                             ?? NSTemporaryDirectory() + "herdr-ios-theme-renders", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
            let attachment = XCTAttachment(image: render.image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            print("HERDR_IOS_RENDER_DIR=\(folder.path)")
        }
    }

    func testSelectedAndPressedRowsUseTheSameQuietRoundedFill() async throws {
        let harness = IOSNativeRenderHarness()
        let row = Color.clear.frame(height: 60)
        let expected = await harness.render(
            row.background(HerdrTheme.codeFill, in: .rect(cornerRadius: 10)),
            width: 120, dynamicType: .defaultSize
        )
        let expectedPixels = try ThemeRaster(expected.image).sha256
        for (selected, pressed) in [(true, false), (false, true), (true, true)] {
            let render = await harness.render(
                row.herdrRowBackground(selected: selected, pressed: pressed),
                width: 120, dynamicType: .defaultSize
            )
            XCTAssertEqual(try ThemeRaster(render.image).sha256, expectedPixels)
        }
    }

    func testInkRemainsTheDefaultBackground() async {
        let harness = IOSNativeRenderHarness()
        let view = Color.clear.frame(height: 32)
        let original = await harness.render(view, width: 32, dynamicType: .defaultSize)
        let explicit = await harness.render(view, width: 32, dynamicType: .defaultSize, background: .ink)
        XCTAssertEqual(original.image.pngData(), explicit.image.pngData())
    }
}
