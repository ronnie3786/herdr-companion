import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import herdr_harness_mac

@Suite("Issue report sheet renders", .serialized)
@MainActor
struct IssueReportRenderTests {
    @Test("Report header and footer share the dusk glass backdrop with the body")
    func rendersDuskGlassChrome() async throws {
        let size = CGSize(width: 680, height: 900)
        var renders: [Bands] = []

        for glassEnabled in [true, false] {
            let result = try await HerdrRenderHarness.render(
                "issue-report-glass-\(glassEnabled ? "on" : "off").png",
                size: size
            ) {
                IssueReportView(model: HerdrRenderFixtures.demoModel())
                    .environment(\.herdrGlassActive, glassEnabled)
                    .environment(\.herdrHazeActive, glassEnabled)
            }

            result.expectSubstantial()
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: result.url)))
            let scale = Double(bitmap.pixelsHigh) / Double(size.height)
            let bands = Bands(
                header: meanRGB(
                    in: bitmap,
                    columns: Int(Double(bitmap.pixelsWide) * 0.40)..<Int(Double(bitmap.pixelsWide) * 0.95),
                    rows: 0..<Int(40 * scale)
                ),
                footer: meanRGB(
                    in: bitmap,
                    columns: Int(Double(bitmap.pixelsWide) * 0.05)..<Int(Double(bitmap.pixelsWide) * 0.55),
                    rows: (bitmap.pixelsHigh - Int(52 * scale))..<bitmap.pixelsHigh
                ),
                body: meanRGB(
                    in: bitmap,
                    columns: Int(Double(bitmap.pixelsWide) * 0.85)..<Int(Double(bitmap.pixelsWide) * 0.98),
                    rows: Int(44 * scale)..<Int(90 * scale)
                )
            )
            renders.append(bands)

            if glassEnabled {
                for (name, band) in [("header", bands.header), ("footer", bands.footer)] {
                    #expect(abs(band.red - bands.body.red) <= 20,
                            "Glass \(name) red \(band.red) did not blend into body \(bands.body.red)")
                    #expect(abs(band.green - bands.body.green) <= 20,
                            "Glass \(name) green \(band.green) did not blend into body \(bands.body.green)")
                    #expect(abs(band.blue - bands.body.blue) <= 20,
                            "Glass \(name) blue \(band.blue) did not blend into body \(bands.body.blue)")
                }
                let text = try recognizedText(result)
                #expect(text.contains("Report"), "The Report title must remain visible")
                #expect(text.contains("Cancel"), "The Cancel action must remain visible")
            } else {
                for (name, band) in [("header", bands.header), ("footer", bands.footer), ("body", bands.body)] {
                    #expect(band.luminance < 100, "Glass-off \(name) luminance was \(band.luminance)")
                    #expect(abs(band.violetBias) < 6, "Glass-off \(name) must remain neutral, bias was \(band.violetBias)")
                }
            }
        }

        let glassOn = renders[0]
        let glassOff = renders[1]
        for (name, on, off) in [("header", glassOn.header, glassOff.header), ("footer", glassOn.footer, glassOff.footer)] {
            #expect(on.violetBias >= off.violetBias + 3,
                    "\(name) violet bias was \(on.violetBias) with Glass on and \(off.violetBias) with Glass off")
        }
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        var violetBias: Double { blue - green }
        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    private struct Bands {
        let header: RGB
        let footer: RGB
        let body: RGB
    }

    private func meanRGB(in bitmap: NSBitmapImageRep, columns: Range<Int>, rows: Range<Int>) -> RGB {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var sampleCount = 0

        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 4) {
            for x in stride(from: columns.lowerBound, to: columns.upperBound, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                red += color.redComponent * 255
                green += color.greenComponent * 255
                blue += color.blueComponent * 255
                sampleCount += 1
            }
        }

        #expect(sampleCount > 0)
        let count = Double(max(sampleCount, 1))
        return RGB(red: red / count, green: green / count, blue: blue / count)
    }

    private func recognizedText(_ result: HerdrRenderHarness.RenderResult) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.005
        try HerdrOCR.perform(request, url: result.url)
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
