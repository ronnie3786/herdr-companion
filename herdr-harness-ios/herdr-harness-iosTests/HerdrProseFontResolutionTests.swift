import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("Herdr prose typography")
struct HerdrProseFontResolutionTests {
    @Test("System prose retains established role sizes and Dynamic Type anchors")
    func roleSizingAndAnchors() {
        let roles = HerdrProse.Role.allCases

        #expect(roles.map(\.baseSize) == [15, 15, 15, 20, 17, 15, 13, 12, 11, 14, 14, 16])
        #expect(roles.map(\.textStyle) == [
            .body, .body, .body, .title2, .title3, .headline,
            .subheadline, .footnote, .caption, .callout, .callout, .body,
        ])
        #expect(HerdrProse.lineSpacing(.bubble) == 6)
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
    @Test("Resolved prose and inline-code fonts scale through the chrome cap")
    func resolvedFontScaling() {
        var normal = EnvironmentValues()
        normal.dynamicTypeSize = .large
        var capped = normal
        capped.dynamicTypeSize = HerdrTheme.maximumDynamicTypeSize
        for role in HerdrProse.Role.allCases {
            let body = HerdrProse.font(role)
            let code = HerdrProse.inlineCodeFont(role)
            #expect(abs(body.resolve(in: normal.fontResolutionContext).pointSize - role.baseSize) < 0.01)
            #expect(abs(code.resolve(in: normal.fontResolutionContext).pointSize - HerdrProse.inlineCodeSize(for: role)) < 0.01)
            #expect(body.resolve(in: capped.fontResolutionContext).pointSize > role.baseSize)
            #expect(code.resolve(in: capped.fontResolutionContext).pointSize > HerdrProse.inlineCodeSize(for: role))
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
