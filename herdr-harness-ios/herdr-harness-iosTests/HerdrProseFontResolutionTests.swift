import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("Herdr prose typography")
struct HerdrProseFontResolutionTests {
    @Test("System prose retains established role sizes and Dynamic Type anchors")
    func roleSizingAndAnchors() {
        let roles = HerdrProse.Role.allCases

        #expect(roles.map(\.baseSize) == [15, 15, 15, 20, 17, 15, 13, 12, 11, 14, 14])
        #expect(roles.map(\.textStyle) == [
            .body, .body, .body, .title2, .title3, .headline,
            .subheadline, .footnote, .caption, .callout, .callout,
        ])
        #expect(HerdrProse.Role.quote.isItalic)
        #expect(!HerdrProse.Role.body.isItalic)
        #expect(HerdrProse.inlineCodeSize(for: .body) == 14)
        #expect(HerdrProse.inlineCodeSize(for: .heading1) == 18)

        // Construct every system and monospaced role font so API drift is a
        // compile-time failure even though SwiftUI Font is intentionally opaque.
        for role in roles {
            _ = HerdrProse.font(role)
            _ = HerdrProse.inlineCodeFont(role)
        }
    }

    @MainActor
    @Test("Unrelated bundled Inter assets remain available")
    func bundledInterAssetsRemainAvailable() {
        #expect(HerdrProse.isInterRegularAvailable())
        for postScriptName in [
            "Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold", "Inter-Italic",
        ] {
            #expect(UIFont(name: postScriptName, size: 15)?.fontName == postScriptName)
        }
    }
}
