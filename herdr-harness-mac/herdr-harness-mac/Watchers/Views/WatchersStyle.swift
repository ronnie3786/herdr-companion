import AppKit
import SwiftUI

/// The approved prototype's look (`avatars-v1-chips.html` over "Dusk glass",
/// with `avatars.css` and `v2-core.css`), in points. CSS pixels map 1:1.
enum WatchersStyle {
    static let mint = HerdrTheme.signal
    static let rose = HerdrTheme.alert
    static let amber = HerdrTheme.working
    /// Run now and Stop run, a step brighter than the other card actions.
    static let actionText = hex(0xD8D0F0)
    /// The prototype's `font-weight: 550`, between medium and semibold.
    static let w550 = NSFont.Weight(0.265)

    static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: alpha)
    }
    /// `color-mix(in srgb, top amount, bottom)`, opaque.
    static func mix(_ top: UInt32, _ amount: Double, over bottom: UInt32) -> Color {
        func channel(_ shift: UInt32) -> Double { (Double(top >> shift & 0xFF) * amount + Double(bottom >> shift & 0xFF) * (1 - amount)) / 255 }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
    }
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: weight) as CTFont)
    }
    /// Where a line box of `size × multiple` puts its baseline, as CSS does.
    static func baseline(_ size: CGFloat, _ multiple: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return (size * multiple - (font.ascender - font.descender)) / 2 + font.ascender
    }
}

extension View {
    /// CSS `line-height`: the extra leading goes between lines and, split in
    /// half, above the first and below the last.
    func watchersLineHeight(_ size: CGFloat, _ multiple: CGFloat) -> some View {
        let font = NSFont.systemFont(ofSize: size)
        let extra = max(0, size * multiple - (font.ascender - font.descender + font.leading))
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// Spacing and type for the grid at the prototype's breakpoints. The
/// prototype keys them on the viewport beside a 168pt rail; these key on the
/// detail column, so 1190 and 1650 become 1022 and 1482.
struct WatchersMetrics: Equatable {
    var columns = 3
    var contentTop: CGFloat = 28, contentSide: CGFloat = 30, contentBottom: CGFloat = 20
    var gap: CGFloat = 19
    var cardTop: CGFloat = 15, cardSide: CGFloat = 24
    var avatar: CGFloat = 82
    var name: CGFloat = 17, who: CGFloat = 10, story: CGFloat = 12.5, storyLine: CGFloat = 2
    /// Next run, the live step, attention and card actions.
    var small: CGFloat = 10
    var actionGap: CGFloat = 7, pauseLead: CGFloat = 10, actionPadding: CGFloat = 12
    var title: CGFloat = 28, intro: CGFloat = 12
    var stacksIntro = false

    static let regular = WatchersMetrics()

    static func forWidth(_ width: CGFloat) -> WatchersMetrics {
        var m = WatchersMetrics()
        if width < 650 {
            m.columns = 1; m.contentTop = 23; m.contentSide = 18; m.contentBottom = 17; m.gap = 18
            m.cardTop = 16; m.cardSide = 28; m.avatar = 88; m.name = 20; m.who = 11; m.story = 14; m.storyLine = 1.9
            m.small = 11; m.actionPadding = 14; m.title = 26; m.stacksIntro = true
        } else if width < 950 {
            m.columns = 2; m.contentTop = 25; m.contentSide = 22; m.contentBottom = 18; m.gap = 15
            m.cardTop = 16; m.cardSide = 25; m.name = 18; m.story = 13; m.title = 25; m.intro = 11
        } else if width < 1022 {
            m.contentTop = 25; m.contentSide = 22; m.contentBottom = 18; m.gap = 15
            m.cardTop = 13; m.cardSide = 19; m.name = 16; m.story = 12; m.actionGap = 4; m.pauseLead = 5; m.title = 26
        } else if width >= 1482 {
            m.contentTop = 35; m.contentSide = 44; m.contentBottom = 24; m.gap = 25
            m.cardTop = 18; m.cardSide = 30; m.avatar = 92; m.name = 19; m.who = 11; m.story = 14; m.small = 11; m.title = 32
        }
        return m
    }
}

/// The prototype's terminal mark: a prompt chevron and a cursor rule, no box.
struct WatcherTerminalGlyph: View {
    var size: CGFloat = 12
    var body: some View {
        Path { path in
            let s = size / 24
            path.move(to: CGPoint(x: 5 * s, y: 8 * s)); path.addLine(to: CGPoint(x: 9 * s, y: 12 * s)); path.addLine(to: CGPoint(x: 5 * s, y: 16 * s))
            path.move(to: CGPoint(x: 12 * s, y: 17 * s)); path.addLine(to: CGPoint(x: 19 * s, y: 17 * s))
        }
        .stroke(style: StrokeStyle(lineWidth: max(1, 1.8 * size / 24), lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
    }
}

/// The prototype's edit mark: an outlined pencil rather than SF's single stroke.
struct WatcherEditGlyph: View {
    var size: CGFloat = 13
    var body: some View {
        Path { path in
            let s = size / 24
            path.move(to: CGPoint(x: 14.5 * s, y: 5.5 * s)); path.addLine(to: CGPoint(x: 18.5 * s, y: 9.5 * s))
            path.move(to: CGPoint(x: 4 * s, y: 20 * s))
            for (x, y) in [(8.5, 19.0), (20, 7.5), (16.5, 4), (5, 15.5)] { path.addLine(to: CGPoint(x: x * s, y: y * s)) }
            path.closeSubpath()
        }
        .stroke(style: StrokeStyle(lineWidth: max(1, 1.65 * size / 24), lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
    }
}

/// The agent chip's face: First Mate's eyes on a small dark disc.
struct WatcherMiniFace: View {
    var size: CGFloat = 16
    var body: some View {
        let k = size / 16 * 10 / 48
        ZStack {
            Circle().fill(WatchersStyle.hex(0x221D33))
            Circle().fill(RadialGradient(colors: [HerdrTheme.accent.opacity(0.3), .clear], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: size * 0.6))
            Circle().strokeBorder(HerdrTheme.accent.opacity(0.5), lineWidth: 1)
            HStack(spacing: 9 * k) {
                ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 4 * k).fill(WatchersStyle.hex(0xDCD9FF)).frame(width: 8 * k, height: 13 * k) }
            }
            .offset(y: -3.5 * k)
        }
        .frame(width: size, height: size)
    }
}

/// Card actions: muted labels that brighten on hover, without a press fade.
struct WatcherActionButtonStyle: ButtonStyle {
    var emphasized = false
    func makeBody(configuration: Configuration) -> some View { ActionBody(configuration: configuration, emphasized: emphasized) }
    private struct ActionBody: View {
        let configuration: Configuration
        let emphasized: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovering && isEnabled ? HerdrTheme.primaryText : emphasized ? WatchersStyle.actionText : HerdrTheme.secondaryText)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.42)
                .onHover { hovering = $0 }
        }
    }
}
