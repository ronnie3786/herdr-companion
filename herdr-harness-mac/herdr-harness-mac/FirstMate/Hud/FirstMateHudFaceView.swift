import AppKit
import SwiftUI

/// First Mate's face on the HUD: the chat window's violet disc and face,
/// grown to 86 pt with an accent ring and 60 ticks.
///
/// - Idle: blinks every 5.2 s and looks toward the pointer.
/// - Pressing: a rose ring fills for 0.42 s, then listening starts.
/// - Listening: rose, wider eyes, a five-bar level meter for a mouth, and 48
///   spectrum ticks outside the ring.
/// - Thinking: the eyes glance side to side and two dashed arcs turn.
/// - Speaking (a reply just landed): the mouth is a pulsing oval.
///
/// Only the blink redraws while idle; everything else animates only while
/// its state lasts. Reduce Motion holds the face still.
struct FirstMateHudFaceView: View {
    let controller: FirstMateHudController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { FirstMateHudGeometry.faceSize }

    private var isAnimating: Bool {
        guard !reduceMotion else { return false }
        switch controller.voicePhase {
        case .pressing, .listening, .transcribing: return true
        case .idle, .heard: return controller.isThinking || controller.isSpeaking
        }
    }

    var body: some View {
        ZStack {
            if isAnimating {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    face(at: context.date)
                }
            } else if reduceMotion {
                face(at: .distantPast)
            } else {
                TimelineView(FirstMateBlinkSchedule(period: FirstMateFaceOrb.blinkPeriod)) { context in
                    face(at: context.date)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let badge = controller.badge {
                Text("\(badge.count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(HerdrTheme.onAttentionBadge)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(FirstMateChatStatusStyle.dotColor(for: badge.status)))
                    // A base-colored edge separates it from the ring.
                    .padding(1.5)
                    .background(Capsule().fill(HerdrTheme.windowBackground))
                    .offset(x: 3, y: 5)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            FirstMateHudFaceHandle(
                onPressBegan: controller.facePressBegan,
                onPressEnded: controller.facePressEnded,
                onDragBegan: controller.faceDragBegan,
                onDragEnded: controller.faceDragEnded,
                menu: faceMenu
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the chat to type. Press and hold to talk.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.toggleChat() }
        .accessibilityAction(named: controller.isListening ? "Send what you said" : "Talk") {
            if controller.isListening { controller.facePressEnded() } else { controller.facePressBegan() }
        }
    }

    private var accessibilityLabel: String {
        guard let badge = controller.badge else { return "First Mate. Nothing needs you." }
        return "First Mate. \(badge.count) \(badge.count == 1 ? "feature needs" : "features need") you."
    }

    private func faceMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = FirstMateHudMenuItem(title: controller.isExpanded ? "Collapse List" : "Show List") { [controller] in
            controller.setExpanded(!controller.isExpanded)
        }
        let chat = FirstMateHudMenuItem(title: "Type to First Mate") { [controller] in controller.openExplicit(.chat) }
        let hide = FirstMateHudMenuItem(title: "Hide First Mate HUD") { [controller] in controller.setEnabled(false) }
        menu.items = [chat, toggle, .separator(), hide]
        return menu
    }

    private func face(at date: Date) -> some View {
        let phase = controller.voicePhase
        let listening = phase == .listening
        let pressProgress: Double = {
            guard case .pressing(let start) = phase else { return 0 }
            return min(max(date.timeIntervalSince(start) / 0.42, 0), 1)
        }()
        let time = date.timeIntervalSinceReferenceDate
        let thinking = controller.isThinking || phase == .transcribing
        var gaze: CGVector = reduceMotion ? .zero : controller.gaze
        if thinking && !reduceMotion { gaze = CGVector(dx: 2.2 * sin(time * 2.6), dy: -0.6) }
        let eyeScale: CGFloat = reduceMotion || listening ? 1 : FirstMateFaceOrb.eyeScale(at: date)
        let mouth: FirstMateHudFaceDrawing.Mouth
        if listening {
            mouth = .meter(Array(controller.voiceSamples.suffix(5)))
        } else if controller.isSpeaking && !reduceMotion {
            mouth = .oval(0.5 + 0.5 * sin(time * 12))
        } else {
            mouth = .smile
        }
        let samples = listening ? controller.voiceSamples : []
        return Canvas { context, canvasSize in
            FirstMateHudFaceDrawing.draw(
                in: &context, size: canvasSize, eyeScale: eyeScale, listening: listening, gaze: gaze, mouth: mouth,
                pressProgress: pressProgress, thinkingPhase: thinking && !reduceMotion ? time : nil, spectrum: samples, time: time
            )
        }
        .frame(width: size + 28, height: size + 28)
        .background {
            Circle().fill((listening ? HerdrTheme.alert : HerdrTheme.accent).opacity(0.26))
                .blur(radius: 12)
                .frame(width: size * 0.84, height: size * 0.84)
        }
    }
}

enum FirstMateHudFaceDrawing {
    enum Mouth: Equatable {
        case smile
        case meter([CGFloat])
        case oval(Double)
    }

    /// `FirstMateFaceOrb.faceColor`, the one color the spec adds: a lighter lavender.
    static let eyeColor = Color(.sRGB, red: 0xD9 / 255, green: 0xD6 / 255, blue: 0xFF / 255, opacity: 1)

    /// Draws the face centered in `size`, which leaves 14 pt around the 86 pt
    /// orb for the arcs and spectrum outside the ring.
    static func draw(
        in context: inout GraphicsContext, size: CGSize, eyeScale: CGFloat, listening: Bool, gaze: CGVector, mouth: Mouth,
        pressProgress: Double, thinkingPhase: TimeInterval?, spectrum: [CGFloat], time: TimeInterval
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = FirstMateHudGeometry.faceSize / 2
        let disc = FirstMateHudGeometry.faceDisc / 2
        let accent = HerdrTheme.accent
        let rose = HerdrTheme.alert
        let tint = listening ? rose : accent

        // 60 ticks between the disc and the ring; every fifth is longer.
        for index in 0..<60 {
            let angle = Double(index) / 60 * 2 * .pi
            let long = index % 5 == 0
            let inner = outer - (long ? 7 : 5.5)
            let outerTick = outer - 3.5
            var tick = Path()
            tick.move(to: point(center, radius: inner, angle: angle))
            tick.addLine(to: point(center, radius: outerTick, angle: angle))
            context.stroke(tick, with: .color(tint.opacity(long ? 0.5 : 0.28)), lineWidth: 1)
        }
        // The outer ring.
        context.stroke(Path(ellipseIn: CGRect(x: center.x - outer + 0.5, y: center.y - outer + 0.5,
                                              width: outer * 2 - 1, height: outer * 2 - 1)),
                       with: .color(tint.opacity(0.8)), lineWidth: 1)

        // The violet disc with its lavender glow and edge.
        let discRect = CGRect(x: center.x - disc, y: center.y - disc, width: disc * 2, height: disc * 2)
        context.fill(Path(ellipseIn: discRect), with: .color(HerdrTheme.firstMateAvatarFill))
        context.fill(Path(ellipseIn: discRect), with: .radialGradient(
            Gradient(colors: [accent.opacity(0.22), accent.opacity(0)]),
            center: CGPoint(x: center.x, y: center.y - disc * 0.32), startRadius: 0, endRadius: disc * 1.1))
        context.stroke(Path(ellipseIn: discRect.insetBy(dx: 0.5, dy: 0.5)), with: .color(tint.opacity(0.6)), lineWidth: 1)

        // The press: a rose ring fills clockwise from the top.
        if pressProgress > 0 {
            var arc = Path()
            arc.addArc(center: center, radius: outer + 3, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * pressProgress), clockwise: false)
            context.stroke(arc, with: .color(rose), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }

        // Listening: 48 spectrum ticks pulse outside the ring.
        if listening {
            let levels = spectrum.isEmpty ? [0.2] : spectrum
            for index in 0..<48 {
                let angle = Double(index) / 48 * 2 * .pi
                let sample = levels[(index * 7) % levels.count]
                let length = 2 + min(max(sample, 0), 1) * 8 * CGFloat(0.6 + 0.4 * sin(time * 9 + Double(index)))
                var tick = Path()
                tick.move(to: point(center, radius: outer + 3, angle: angle))
                tick.addLine(to: point(center, radius: outer + 3 + max(length, 1.5), angle: angle))
                context.stroke(tick, with: .color(rose.opacity(0.7)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }

        // Thinking: two dashed arcs turn outside the ring.
        if let phase = thinkingPhase {
            for index in 0..<2 {
                let start = phase * 90 + Double(index) * 180
                var arc = Path()
                arc.addArc(center: center, radius: outer + 5, startAngle: .degrees(start), endAngle: .degrees(start + 70), clockwise: false)
                context.stroke(arc, with: .color(accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 3]))
            }
        }

        // The face, in the chat window's 48-unit space at one point per unit.
        var face = context
        face.translateBy(x: center.x + gaze.dx, y: center.y + gaze.dy)
        face.addFilter(.shadow(color: tint.opacity(0.8), radius: 2))
        let eyeColor = listening ? rose : Self.eyeColor
        let width: CGFloat = listening ? 8 * 1.16 : 8
        let height: CGFloat = (listening ? 12 * 1.16 : 12) * eyeScale
        for x: CGFloat in [-8.5, 8.5] {
            let eye = CGRect(x: x - width / 2, y: -4 - height / 2, width: width, height: height)
            face.fill(Path(roundedRect: eye, cornerRadius: min(4, height / 2)), with: .color(eyeColor))
        }
        switch mouth {
        case .smile:
            var smile = Path()
            smile.move(to: CGPoint(x: -5.5, y: 9.5))
            smile.addQuadCurve(to: CGPoint(x: 5.5, y: 9.5), control: CGPoint(x: 0, y: 13.5))
            face.stroke(smile, with: .color(eyeColor), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        case .meter(let levels):
            let bars = levels.isEmpty ? [CGFloat](repeating: 0.15, count: 5) : levels + [CGFloat](repeating: 0.15, count: max(0, 5 - levels.count))
            for (index, level) in bars.prefix(5).enumerated() {
                let barHeight = 2 + min(max(level, 0), 1) * 7
                let x = CGFloat(index - 2) * 3.4
                face.fill(Path(roundedRect: CGRect(x: x - 1.1, y: 11 - barHeight / 2, width: 2.2, height: barHeight), cornerRadius: 1.1),
                          with: .color(eyeColor))
            }
        case .oval(let pulse):
            let ovalHeight = 3 + 3 * pulse
            face.stroke(Path(ellipseIn: CGRect(x: -3.5, y: 11 - ovalHeight / 2, width: 7, height: ovalHeight)),
                        with: .color(eyeColor), lineWidth: 2)
        }
    }

    private static func point(_ center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }
}

/// Click, press-and-hold, and drag on First Mate's face, told apart the way
/// the agent HUD's drag handle does: moving more than 4 pt drags the whole
/// HUD; letting go first is a press that ended (a click, or the end of
/// talking once the hold started). Right-click shows the face's menu.
struct FirstMateHudFaceHandle: NSViewRepresentable {
    let onPressBegan: () -> Void
    let onPressEnded: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> FirstMateHudFaceHandleView { FirstMateHudFaceHandleView() }

    func updateNSView(_ view: FirstMateHudFaceHandleView, context: Context) {
        view.onPressBegan = onPressBegan
        view.onPressEnded = onPressEnded
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.makeMenu = menu
    }
}

@MainActor
final class FirstMateHudFaceHandleView: NSView {
    var onPressBegan: (() -> Void)?
    var onPressEnded: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var makeMenu: (() -> NSMenu)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the round face takes the pointer; the corners stay click-through
    /// to the orbs and chevron beside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = min(bounds.width, bounds.height) / 2
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= radius ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onPressBegan?()
        let start = window.convertPoint(toScreen: event.locationInWindow)
        var dragged = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { [weak self] tracked, stop in
            guard let self, let tracked else { stop.pointee = true; return }
            switch tracked.type {
            case .leftMouseDragged:
                let location = window.convertPoint(toScreen: tracked.locationInWindow)
                guard hypot(location.x - start.x, location.y - start.y) > 4 else { return }
                stop.pointee = true
                dragged = true
                self.onDragBegan?()
                window.performDrag(with: event)
                self.onDragEnded?()
            case .leftMouseUp:
                stop.pointee = true
            default:
                break
            }
        }
        if !dragged { onPressEnded?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A menu item that runs a closure.
@MainActor
final class FirstMateHudMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        handler()
    }
}
