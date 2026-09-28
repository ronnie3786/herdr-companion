import SwiftUI

// The HUD's small pieces, in the chat window's style: the violet emoji disc,
// the status colors, and flat unread dots with no glow or dashed rings.

/// A feature's orb: the chat window's emoji disc inside a six-step progress
/// ring in the status color, with the flat unread dot at its top right.
struct FirstMateHudHaloOrb: View {
    let item: FirstMateHudItem
    var size: CGFloat = FirstMateHudGeometry.orbSize

    var body: some View {
        let color = FirstMateChatStatusStyle.dotColor(for: item.hudStatus)
        ZStack {
            Circle()
                .fill(color.opacity(item.hudStatus == .idle ? 0.10 : 0.22))
                .blur(radius: size * 0.14)
                .padding(size * 0.06)
            FirstMateHudStepRing(
                segments: FirstMateHudProgress.segments(status: item.hudStatus, step: item.conversation.stepIndex,
                                                        fraction: item.conversation.stepFraction),
                color: color,
                lineWidth: size >= 34 ? 2.2 : size >= 26 ? 2 : 1.6
            )
            FirstMateEmojiDisc(emoji: item.emoji, size: size * 0.74)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if item.showsDot {
                FirstMateHudUnreadDot(color: color, size: size >= 26 ? 9 : 7)
                    .offset(x: size * 0.08, y: -size * 0.08)
            }
        }
    }
}

/// The chat window's unread dot: flat, in the color of why it needs you,
/// with a thin base-colored edge so it reads over the ring.
struct FirstMateHudUnreadDot: View {
    let color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .padding(1.5)
            .background(Circle().fill(HerdrTheme.windowBackground))
            .accessibilityHidden(true)
    }
}

/// Six arcs around a circle, one per step (Plan, Build, Review, QA, PR,
/// Merge), filled clockwise from the top.
struct FirstMateHudStepRing: View {
    let segments: [Double]
    let color: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - lineWidth / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let count = max(segments.count, 1)
            let span = 360.0 / Double(count)
            let gap = 9.0
            for (index, fill) in segments.enumerated() {
                let start = -90 + Double(index) * span + gap / 2
                let end = start + span - gap
                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                context.stroke(track, with: .color(HerdrTheme.primaryText.opacity(0.14)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                guard fill > 0 else { continue }
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .degrees(start),
                           endAngle: .degrees(start + (end - start) * min(fill, 1)), clockwise: false)
                context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The "+N" orb: one arc per tucked feature in its status color, and the
/// unread dot when any of them has one.
struct FirstMateHudMoreOrb: View {
    let tucked: [FirstMateHudItem]
    var size: CGFloat = FirstMateHudGeometry.orbSize
    var showsCount = true

    var body: some View {
        ZStack {
            Canvas { context, canvasSize in
                let lineWidth: CGFloat = size >= 34 ? 2.2 : 2
                let radius = min(canvasSize.width, canvasSize.height) / 2 - lineWidth / 2
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let count = max(tucked.count, 1)
                let span = 360.0 / Double(count)
                let gap = count > 1 ? min(8.0, span * 0.3) : 0
                for (index, item) in tucked.enumerated() {
                    let start = -90 + Double(index) * span + gap / 2
                    var arc = Path()
                    arc.addArc(center: center, radius: radius, startAngle: .degrees(start),
                               endAngle: .degrees(start + span - gap), clockwise: false)
                    context.stroke(arc, with: .color(FirstMateChatStatusStyle.dotColor(for: item.hudStatus).opacity(0.85)),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
            Circle().fill(HerdrTheme.firstMateAvatarFill)
                .overlay { Circle().strokeBorder(HerdrTheme.accent.opacity(0.20), lineWidth: 1) }
                .frame(width: size * 0.74, height: size * 0.74)
            if showsCount {
                Text("+\(tucked.count)")
                    .font(.system(size: size * 0.34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let unread = tucked.filter(\.showsDot).min(by: { FirstMateHudOrder.urgency($0.hudStatus) < FirstMateHudOrder.urgency($1.hudStatus) }) {
                FirstMateHudUnreadDot(color: FirstMateChatStatusStyle.dotColor(for: unread.hudStatus), size: 9)
                    .offset(x: size * 0.08, y: -size * 0.08)
            }
        }
    }
}

/// The slat's six-segment bar.
struct FirstMateHudStepBar: View {
    let item: FirstMateHudItem
    var height: CGFloat = 3
    var spacing: CGFloat = 3

    var body: some View {
        let color = FirstMateChatStatusStyle.dotColor(for: item.hudStatus)
        HStack(spacing: spacing) {
            ForEach(Array(FirstMateHudProgress.segments(status: item.hudStatus, step: item.conversation.stepIndex,
                                                        fraction: item.conversation.stepFraction).enumerated()), id: \.offset) { _, fill in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(HerdrTheme.primaryText.opacity(0.10))
                        Capsule().fill(color).frame(width: proxy.size.width * min(max(fill, 0), 1))
                    }
                }
                .frame(height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The unread speech bubble beside a slat: accent, with three dots.
struct FirstMateHudSpeechBubble: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(HerdrTheme.accent)
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(HerdrTheme.onPrimary).frame(width: 3, height: 3)
                }
            }
        }
        .frame(width: FirstMateHudGeometry.bubbleSize.width, height: FirstMateHudGeometry.bubbleSize.height)
        .overlay(alignment: .bottomLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 7, y: 0))
                path.addLine(to: CGPoint(x: 1, y: 5))
                path.closeSubpath()
            }
            .fill(HerdrTheme.accent)
            .frame(width: 7, height: 5)
            .offset(x: 4, y: 4)
        }
    }
}

/// A HUD card's surface: the agent HUD's legible glass over its own dusk,
/// a hairline edge, and a soft shadow.
struct FirstMateHudCardSurface: ViewModifier {
    var cornerRadius: CGFloat = HerdrTheme.Radius.card
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background {
                HerdrGlassBackground(level: HerdrTheme.Glass.hud, cornerRadius: cornerRadius, drawsDusk: true, duskRegion: .whole)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.45) } ?? HerdrTheme.outline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.32), radius: 14, y: 5)
            .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
    }
}

extension View {
    func firstMateHudCard(cornerRadius: CGFloat = HerdrTheme.Radius.card, tint: Color? = nil) -> some View {
        modifier(FirstMateHudCardSurface(cornerRadius: cornerRadius, tint: tint))
    }
}
