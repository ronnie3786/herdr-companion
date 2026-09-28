import SwiftUI

// Small pieces the chat window's views share: status colors and words, the
// emoji disc, First Mate's face, and the breathing "working" label.

/// Status colors and words for the chat window. The inspector keeps its
/// native mapping (`FirstMateStatusColors`), where awaiting direction is green.
enum FirstMateChatStatusStyle {
    /// Ready to plan's grey, used for dots and tints only (never as text).
    static let idleTint = Color(.sRGB, red: 0x8E / 255, green: 0x8E / 255, blue: 0x96 / 255, opacity: 1)

    /// The status word's text color. Quiet statuses read in tertiary ink.
    static func color(for status: FirstMateHudStatus) -> Color {
        switch status {
        case .blocked: HerdrTheme.alert
        case .turn: HerdrTheme.attentionBadge
        case .ready: HerdrTheme.signal
        case .working: HerdrTheme.working
        case .idle, .done, .unknown: HerdrTheme.tertiaryText
        }
    }

    /// Dots, capsule tints, and status edges keep the raw color even for the
    /// quiet statuses: complete is green and ready to plan is grey.
    static func dotColor(for status: FirstMateHudStatus) -> Color {
        switch status {
        case .blocked: HerdrTheme.alert
        case .turn: HerdrTheme.attentionBadge
        case .ready, .done: HerdrTheme.signal
        case .working: HerdrTheme.working
        case .idle, .unknown: idleTint
        }
    }

    static func tintColor(for status: FirstMateHudStatus) -> Color { dotColor(for: status) }

    static func label(for status: FirstMateHudStatus) -> String {
        switch status {
        case .blocked: "Blocked"
        case .turn: "Your turn"
        case .ready: "Ready for review"
        case .working: "Working"
        case .idle: "Ready to plan"
        case .done: "Complete"
        case .unknown: "Status unknown"
        }
    }

    /// The row's word: a working feature shows its step ("In review"), or
    /// "Working" when the step is unknown.
    static func word(for conversation: FirstMateConversation) -> String {
        if conversation.hudStatus == .working, let step = conversation.stepIndex {
            return FirstMateChatSteps.doing[step]
        }
        return label(for: conversation.hudStatus)
    }

    /// Quiet words use tertiary ink at weight 500.
    static func isQuiet(_ status: FirstMateHudStatus) -> Bool {
        [.idle, .done, .unknown].contains(status)
    }

    /// "Step 4 of 6, QA", "All six steps done", or nil when the step is unknown.
    static func stepText(for conversation: FirstMateConversation) -> String? {
        if conversation.hudStatus == .done { return "All six steps done" }
        guard let step = conversation.stepIndex else { return nil }
        return "Step \(step + 1) of \(FirstMateChatSteps.names.count), \(FirstMateChatSteps.names[step])"
    }
}

/// An emoji on First Mate's dark violet disc, with a faint lavender top
/// highlight and a 1 pt lavender edge. No ring and no status badge. `edge`
/// gives agent and picker avatars a status-colored edge instead.
struct FirstMateEmojiDisc: View {
    let emoji: String
    let size: CGFloat
    var edge: Color? = nil

    var body: some View {
        ZStack {
            Circle().fill(HerdrTheme.firstMateAvatarFill)
            // CSS `radial-gradient(circle at 50% 26%, accent 20%, transparent 68%)`:
            // 68% of the distance to the farthest corner.
            Circle().fill(RadialGradient(
                colors: [HerdrTheme.accent.opacity(0.20), HerdrTheme.accent.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.26),
                startRadius: 0,
                endRadius: size * 0.68 * hypot(0.5, 0.74)
            ))
            Circle().strokeBorder(edge.map { $0.opacity(0.55) } ?? HerdrTheme.accent.opacity(0.20), lineWidth: 1)
            Text(emoji)
                .font(.system(size: size * 0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .background {
            if let edge { Circle().fill(edge.opacity(0.35)).blur(radius: 3).padding(2) }
        }
        .accessibilityHidden(true)
    }
}

/// First Mate's face: two rounded eyes and a smile in soft lavender on the
/// violet disc. It blinks every 5.2 s, in step with every other face on
/// screen, and holds still under Reduce Motion.
struct FirstMateFaceOrb: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let faceColor = Color(.sRGB, red: 0xD9 / 255, green: 0xD6 / 255, blue: 0xFF / 255, opacity: 1)
    static let blinkPeriod: TimeInterval = 5.2

    var body: some View {
        ZStack {
            Circle().fill(HerdrTheme.firstMateAvatarFill)
            Circle().fill(RadialGradient(
                colors: [HerdrTheme.accent.opacity(0.22), HerdrTheme.accent.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0,
                endRadius: size * 0.64 * hypot(0.5, 0.66)
            ))
            Circle().strokeBorder(HerdrTheme.accent.opacity(0.60), lineWidth: 1)
            face.frame(width: size * 0.62, height: size * 0.62)
        }
        .frame(width: size, height: size)
        .background {
            Circle().fill(HerdrTheme.accent.opacity(0.30)).blur(radius: 7).padding(size * 0.08)
        }
        .overlay {
            if size > 26 { Circle().strokeBorder(HerdrTheme.accent.opacity(0.32), lineWidth: 1).padding(-3) }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var face: some View {
        if reduceMotion {
            FirstMateFace(eyeScale: 1)
        } else {
            TimelineView(FirstMateBlinkSchedule(period: Self.blinkPeriod)) { context in
                FirstMateFace(eyeScale: Self.eyeScale(at: context.date))
            }
        }
    }

    /// Eyes close to 10% at 95.5% of each cycle; the phase comes from the
    /// wall clock so every face blinks together.
    static func eyeScale(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: blinkPeriod) / blinkPeriod
        let (start, peak, end) = (0.93, 0.955, 0.98)
        guard phase > start, phase < end else { return 1 }
        let closing = phase < peak ? (phase - start) / (peak - start) : (end - phase) / (end - peak)
        return 1 - 0.9 * closing
    }
}

/// The face drawn in the reference's 48-unit coordinate space.
private struct FirstMateFace: View {
    let eyeScale: CGFloat

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 48
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: unit, y: unit)
            context.addFilter(.shadow(color: HerdrTheme.accent.opacity(0.8), radius: 2))
            let height: CGFloat = 12 * eyeScale
            for x: CGFloat in [-12.5, 4.5] {
                let eye = CGRect(x: x, y: -4 - height / 2, width: 8, height: height)
                context.fill(Path(roundedRect: eye, cornerRadius: min(4, height / 2)), with: .color(FirstMateFaceOrb.faceColor))
            }
            var mouth = Path()
            mouth.move(to: CGPoint(x: -5.5, y: 9.5))
            mouth.addQuadCurve(to: CGPoint(x: 5.5, y: 9.5), control: CGPoint(x: 0, y: 13.5))
            context.stroke(mouth, with: .color(FirstMateFaceOrb.faceColor),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }
}

/// Redraws only around each blink: a single entry while the eyes are open,
/// then about 30 frames a second for the quarter second they close.
struct FirstMateBlinkSchedule: TimelineSchedule {
    let period: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(period: period, pending: startDate, lowFrequency: mode == .lowFrequency)
    }

    struct Entries: Sequence, IteratorProtocol {
        let period: TimeInterval
        var pending: Date
        let lowFrequency: Bool

        mutating func next() -> Date? {
            let current = pending
            let time = current.timeIntervalSinceReferenceDate
            let cycleStart = time - time.truncatingRemainder(dividingBy: period)
            let blinkStart = cycleStart + period * 0.93
            let blinkEnd = cycleStart + period * 0.98
            if lowFrequency || time < blinkStart || time >= blinkEnd {
                let upcoming = time < blinkStart ? blinkStart : cycleStart + period + period * 0.93
                pending = Date(timeIntervalSinceReferenceDate: upcoming)
            } else {
                // Inside the blink: frame by frame, then one frame after it opens.
                let frame = time + 1.0 / 30
                pending = Date(timeIntervalSinceReferenceDate: frame < blinkEnd ? frame : blinkEnd + 0.001)
            }
            return current
        }
    }
}

/// The working label's breath: opacity 1 → ``floor`` → 1 over 2.4 s. The phase
/// comes from the wall clock so every row breathes together. Off under Reduce
/// Motion.
struct FirstMateBreathing: ViewModifier {
    static let period: TimeInterval = 2.4
    /// The dimmest opacity: kept at 0.75 over the darkened Glass/Haze
    /// backgrounds, where `working` still clears 4.5:1 over the sidebar and
    /// pane glass at the dusk's brightest point, hovered or selected
    /// (`HerdrThemeAccessibilityTests`).
    static let floor = 0.75

    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                content.opacity(Self.opacity(at: context.date))
            }
        } else {
            content
        }
    }

    /// An ease-in-out breath: 1 at the start of each period, ``floor`` halfway.
    static func opacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return floor + (1 - floor) * (0.5 + 0.5 * cos(2 * .pi * phase))
    }
}

extension View {
    func firstMateBreathing(_ isActive: Bool = true) -> some View {
        modifier(FirstMateBreathing(isActive: isActive))
    }
}
