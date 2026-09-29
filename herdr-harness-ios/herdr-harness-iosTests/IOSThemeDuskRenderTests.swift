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
        ] {
            let render = await IOSNativeRenderHarness().render(
                HerdrThemeSampleContent(), width: width, dynamicType: size, background: .dusk
            )
            XCTAssertTrue(render.drewHierarchy)
            XCTAssertEqual(render.bounds.width, width)
            XCTAssertGreaterThan(render.fittingSize.height, 300)
            XCTAssertLessThan(render.fittingSize.height, 3_000)
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

    func testInkRemainsTheDefaultBackground() async {
        let harness = IOSNativeRenderHarness()
        let view = Color.clear.frame(height: 32)
        let original = await harness.render(view, width: 32, dynamicType: .defaultSize)
        let explicit = await harness.render(view, width: 32, dynamicType: .defaultSize, background: .ink)
        XCTAssertEqual(original.image.pngData(), explicit.image.pngData())
    }
}
