import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("iOS theme typography and motion")
@MainActor
struct HerdrThemeFoundationTests {
    @Test("Every ramp follows its Dynamic Type anchor through accessibility3")
    func dynamicType() {
        for style: Font.TextStyle in [.caption2, .caption, .footnote, .subheadline, .callout, .body, .headline, .largeTitle] {
            let ramp = HerdrFont.ramp(style)
            let normal = HerdrFont.scaledSize(ramp.size, relativeTo: style, dynamicType: .large)
            let accessible = HerdrFont.scaledSize(ramp.size, relativeTo: style, dynamicType: .accessibility3)
            #expect(abs(normal - ramp.size) < 0.001)
            #expect(accessible > normal)
        }
        #expect(HerdrFont.ramp(.body).size == 16)
        #expect(HerdrFont.ramp(.caption2).size == 11)
        #expect(HerdrFont.ramp(.headline).size == 17)
    }

    @Test("The face glow is cached, transparent and bounded across blink frames")
    func faceArtwork() throws {
        #expect(FirstMateFaceArtwork.frameCount == 31)
        let open = FirstMateFaceArtwork.image(eyeScale: 1)
        let closed = FirstMateFaceArtwork.image(eyeScale: 0.1)
        #expect(open === FirstMateFaceArtwork.image(eyeScale: 1))
        #expect(open === FirstMateFaceArtwork.image(eyeScale: 2))
        #expect(closed === FirstMateFaceArtwork.image(eyeScale: 0))
        let openPixels = try ThemeRaster(open), closedPixels = try ThemeRaster(closed)
        #expect(openPixels.width == 288 && openPixels.height == 288)
        #expect(!openPixels.isOpaque && !closedPixels.isOpaque)
        #expect(openPixels.sha256 != closedPixels.sha256)
        let alpha = stride(from: 3, to: openPixels.bytes.count, by: 4).reduce(0) { $0 + Int(openPixels.bytes[$1]) }
        #expect(alpha > 0, "Offscreen rendering must not cache an empty face")
    }

    @Test("Breathing and blinking retain the shipped Mac timings")
    func motion() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        #expect(FirstMateBreathing.period == 2.4)
        #expect(FirstMateBreathing.opacity(at: date) == 1)
        #expect(FirstMateBreathing.opacity(at: date.addingTimeInterval(1.2)) == 0.75)
        #expect(FirstMateFaceOrb.blinkPeriod == 5.2)
        #expect(FirstMateFaceOrb.eyeScale(at: date) == 1)
        #expect(abs(FirstMateFaceOrb.eyeScale(at: date.addingTimeInterval(5.2 * 0.955)) - 0.1) < 0.001)
        var entries = FirstMateBlinkSchedule(period: 5.2).entries(from: date, mode: .normal)
        #expect(entries.next() == date)
        #expect(entries.next() == date.addingTimeInterval(5.2 * 0.93))
    }
}
