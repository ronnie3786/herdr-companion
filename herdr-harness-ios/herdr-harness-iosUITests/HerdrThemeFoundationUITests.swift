import XCTest
import UIKit

@MainActor
final class HerdrThemeFoundationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDuskSampleHasReachableControls() throws {
        let app = demo(sample: true)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["First Mate"].waitForExistence(timeout: 10))
        try capture("theme-dusk-simulator-402", app)
        try assertFaceVisible(in: app)
        for title in ["Overview", "Agents", "Documents"] {
            let tab = app.buttons[title]
            assertTouchTarget(tab)
        }
        let send = app.buttons["theme-sample-send"]
        scrollTo(send, app)
        assertTouchTarget(send)
        send.tap()
        XCTAssertTrue(app.staticTexts["Direction received."].waitForExistence(timeout: 5))
    }

    func testAppearanceTogglesAndExistingTabsRemainAvailable() throws {
        let app = demo()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 10))
        try capture("phase-0-first-mate-402", app)
        for tab in ["Agents", "Attention", "Notes", "Settings"] {
            app.tabBars.buttons[tab].tap()
            try capture("phase-0-\(tab.lowercased())-402", app)
        }
        let glass = app.switches["settings-appearance-glass"]
        scrollTo(glass, app)
        let haze = app.switches["settings-appearance-haze"]
        XCTAssertTrue(glass.exists && haze.exists)
        setToggle(glass, on: true)
        XCTAssertTrue(haze.isEnabled)
        setToggle(haze, on: false)
        setToggle(glass, on: false)
        XCTAssertTrue(haze.wait(for: \.isEnabled, toEqual: false, timeout: 3))
        XCTAssertEqual(haze.value as? String, "0", "Disabling Glass must retain the Haze choice")
        try capture("phase-0-settings-glass-off-402", app)
        setToggle(glass, on: true)
        XCTAssertTrue(haze.wait(for: \.isEnabled, toEqual: true, timeout: 3))
        XCTAssertEqual(haze.value as? String, "0")
        setToggle(haze, on: true)
        try capture("phase-0-settings-appearance-402", app)
        app.tabBars.buttons["First Mates"].tap()
        XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 5))
    }

    func testSampleAtAccessibility3UsesCapAndKeepsControlsReachable() throws {
        let app = demo(sample: true, extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["First Mate"].waitForExistence(timeout: 10))
        try capture("theme-dusk-simulator-accessibility3-top", app)
        for title in ["Overview", "Agents", "Documents"] {
            let tab = app.buttons[title]
            assertTouchTarget(tab)
            XCTAssertTrue(tab.isHittable)
            XCTAssertTrue(app.frame.contains(tab.frame), "The capped tab must not clip offscreen")
        }
        let textSize = app.staticTexts["theme-sample-text-size"]
        XCTAssertTrue(textSize.waitForExistence(timeout: 5))
        XCTAssertEqual(textSize.label, "Text size: xxxLarge")
        let send = app.buttons["theme-sample-send"]
        scrollTo(send, app)
        assertTouchTarget(send)
        XCTAssertTrue(send.isHittable)
        try capture("theme-dusk-simulator-accessibility3-controls", app)
        send.tap()
        XCTAssertTrue(app.staticTexts["Direction received."].waitForExistence(timeout: 5))
    }

    private func demo(sample: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrFirstMateDemo", "-HerdrResetFirstMateScope",
                               "-herdr.firstMate.appearance", "dark", "-herdr.smartAlerts", "NO"]
            + (sample ? ["-HerdrThemeDuskSample"] : []) + extra
        app.launch()
        return app
    }

    private func assertFaceVisible(in app: XCUIApplication) throws {
        // A live TimelineView must show the glyph, not just its violet disc.
        // An offscreen render alone does not establish visibility during a live animation.
        let header = app.staticTexts["theme-sample-header"].firstMatch.frame
        XCTAssertGreaterThan(header.height, 0)
        let screen = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(screen.width) / app.frame.width
        // The fixture has 20pt padding and a 52pt disc. The combined header's
        // bounds can include its glow. Restrict the crop to the avatar column,
        // above the tabs, so unrelated white text cannot satisfy the check.
        let facePoints = CGRect(x: app.frame.minX + 20, y: header.minY, width: 52,
                                height: min(header.maxY, app.buttons["Overview"].frame.minY) - header.minY)
        XCTAssertGreaterThan(facePoints.height, 0)
        let face = facePoints.applying(CGAffineTransform(scaleX: scale, y: scale))
        let image = try XCTUnwrap(screen.cropping(to: face))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drew)
        let glyphPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 180 && pixels[$0 + 1] > 180 && pixels[$0 + 2] > 180
        }.count
        print("HERDR_FACE_GLYPHS rect=\(face) pixels=\(glyphPixels)")
        XCTAssertGreaterThan(glyphPixels, 30, "The eyes and smile must remain visible, including while blinking")
    }

    private func assertTouchTarget(_ element: XCUIElement) {
        // XCTest's screen-coordinate conversion can return 43.999999999999986
        // for an exact 44pt frame. Allow floating-point noise, not a pixel.
        XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 0.000_001)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 0.000_001)
    }

    private func setToggle(_ toggle: XCUIElement, on: Bool) {
        let value = on ? "1" : "0"
        guard toggle.value as? String != value else { return }
        // SwiftUI exposes the entire Form row as a switch. Its center can be
        // empty label space; tap the actual trailing control instead.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed, toggle.debugDescription)
    }

    private func scrollTo(_ element: XCUIElement, _ app: XCUIApplication) {
        let visible = app.frame.insetBy(dx: 0, dy: 100)
        for _ in 0..<12 {
            if element.exists && element.isHittable && visible.contains(element.frame) { return }
            let downward = element.exists && element.frame.minY < visible.minY
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.4 : 0.7))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.7 : 0.4)))
        }
        XCTAssertTrue(element.exists && element.isHittable && visible.contains(element.frame), element.debugDescription)
    }

    private func capture(_ name: String, _ app: XCUIApplication) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let root = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
                       ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"]
                       ?? NSTemporaryDirectory() + "herdr-ios-theme-ui", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: root.appending(path: name + ".png"))
    }
}
