import SwiftUI

/// The reference face rendered as vectors, including its sixty-tick instrument ring.
/// Animation stays inside this small view and stops when the scene is inactive.
struct HomeAvatar: View {
    var mood: HomeMood = .calm
    var size: CGFloat = 26
    var showsRing = false
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var motion = false
    @State private var blinking = false
    @State private var look = CGSize.zero
    @State private var isMounted = false
    @State private var isOnscreen = true
    @State private var glancing = false

    private var moving: Bool { animated && isMounted && isOnscreen && !reduceMotion && scenePhase == .active }
    private var ringColor: Color {
        switch mood {
        case .happy: HomePalette.signal
        case .concerned: HomePalette.alert
        default: HomePalette.accent
        }
    }

    var body: some View {
        ZStack {
            if showsRing {
                ring.frame(width: size * 1.24, height: size * 1.24)
            }
            disc
                .frame(width: size * (showsRing ? 0.84 : 1), height: size * (showsRing ? 0.84 : 1))
                .offset(y: showsRing && moving ? (motion ? -3 : 3) : 0)
                .animation(moving ? .easeInOut(duration: 3).repeatForever(autoreverses: true) : nil, value: motion)
        }
        .frame(width: size, height: size)
        .onAppear { isMounted = true }
        .onDisappear { isMounted = false }
        .onScrollVisibilityChange(threshold: 0.01) { isOnscreen = $0 }
        .onContinuousHover { phase in
            guard showsRing, moving else { return }
            switch phase {
            case .active(let point):
                look = CGSize(width: (point.x - size / 2) / size * 4, height: (point.y - size / 2) / size * 3)
            case .ended: look = .zero
            }
        }
        .task(id: moving) {
            motion = moving
            blinking = false
            if !moving { look = .zero }
            guard moving else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4.84))
                    withAnimation(.easeInOut(duration: 0.12)) { blinking = true }
                    try await Task.sleep(for: .milliseconds(130))
                    withAnimation(.easeInOut(duration: 0.18)) { blinking = false }
                    try await Task.sleep(for: .milliseconds(230))
                }
            } catch { /* SwiftUI cancels the blink task when this face leaves the screen. */ }
        }
        .task(id: mood == .thinking && moving) {
            glancing = false
            guard mood == .thinking && moving else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            glancing = true
        }
        .accessibilityHidden(true)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(showsRing ? HomePalette.base.opacity(0.86) : HomePalette.color(0x2A2244))
            Circle().fill(RadialGradient(colors: [HomePalette.accent.opacity(0.24), .clear],
                center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0,
                endRadius: size * (showsRing ? 0.52 : 0.64)))
            HomeAvatarFace(mood: mood, blinking: blinking)
                .frame(width: size * (showsRing ? 0.4368 : 0.62), height: size * (showsRing ? 0.4368 : 0.62))
                .offset(look)
                .offset(x: mood == .thinking && moving ? (glancing ? 2.4 : -2.4) : 0)
                .animation(moving ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true) : nil, value: glancing)
                .animation(moving ? .easeOut(duration: 0.25) : nil, value: look)
                .shadow(color: ringColor.opacity(0.85), radius: showsRing ? 6 : 4)
        }
        .overlay(Circle().strokeBorder(showsRing ? HomePalette.ink.opacity(0.13) : ringColor.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(showsRing ? 0.45 : 0), radius: 20, y: 18)
        .shadow(color: ringColor.opacity(showsRing ? 0.28 : 0.4), radius: showsRing ? 40 : 7)
    }

    private var ring: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / 120
            ZStack {
                Circle().stroke(ringColor.opacity(0.10), lineWidth: 9 * unit)
                    .padding(16 * unit)
                HomeAvatarTicks().stroke(HomePalette.ink.opacity(0.2), lineWidth: 0.8 * unit)
                    .rotationEffect(.degrees(motion && moving ? 360 : 0))
                    .animation(moving ? .linear(duration: 120).repeatForever(autoreverses: false) : nil, value: motion)
                Circle().stroke(ringColor.opacity(0.8), lineWidth: 1.3 * unit)
                    .padding(14 * unit)
                if mood == .thinking {
                    Circle().stroke(ringColor, style: StrokeStyle(lineWidth: 1.3 * unit, lineCap: .round, dash: [60, 22, 14, 22].map { $0 * unit }))
                        .padding(3 * unit)
                        .rotationEffect(.degrees(motion && moving ? 360 : 0))
                        .animation(moving ? .linear(duration: 1.6).repeatForever(autoreverses: false) : nil, value: motion)
                    Circle().stroke(ringColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.3 * unit, lineCap: .round, dash: [5 * unit, 10 * unit]))
                        .padding(unit)
                        .rotationEffect(.degrees(motion && moving ? -360 : 0))
                        .animation(moving ? .linear(duration: 2.6).repeatForever(autoreverses: false) : nil, value: motion)
                }
            }
        }
    }
}

private struct HomeAvatarTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 120
        return Path { path in
            for index in 0..<60 {
                let angle = Double(index) / 60 * .pi * 2
                let inner: CGFloat = index.isMultiple(of: 5) ? 50 : 51.5
                path.move(to: CGPoint(x: rect.midX + cos(angle) * inner * unit, y: rect.midY + sin(angle) * inner * unit))
                path.addLine(to: CGPoint(x: rect.midX + cos(angle) * 54 * unit, y: rect.midY + sin(angle) * 54 * unit))
            }
        }
    }
}

private struct HomeAvatarFace: View {
    var mood: HomeMood
    var blinking: Bool

    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / 48
            let eyeColor = mood == .concerned ? HomePalette.color(0xF3D5DD) : HomePalette.color(0xD9D6FF)
            ZStack {
                HStack(spacing: 9 * unit) {
                    Capsule().fill(eyeColor)
                    Capsule().fill(eyeColor)
                }
                .frame(width: 25 * unit, height: 12 * unit)
                .scaleEffect(x: 1, y: blinking ? 0.1 : 1)
                .offset(y: -4 * unit)
                HomeAvatarMouth(mood: mood)
                    .stroke(eyeColor, style: StrokeStyle(lineWidth: 2.1 * unit, lineCap: .round))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct HomeAvatarMouth: Shape {
    let mood: HomeMood

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 48
        let width: CGFloat
        let y: CGFloat
        let curve: CGFloat
        switch mood {
        case .attentive: (width, y, curve) = (9, 10, 2.6)
        case .calm: (width, y, curve) = (11, 9.5, 4)
        case .happy: (width, y, curve) = (14, 8, 7.5)
        case .concerned: (width, y, curve) = (10, 11.6, -1.8)
        case .thinking: (width, y, curve) = (7, 10.5, 0)
        }
        return Path { path in
            path.move(to: CGPoint(x: rect.midX - width / 2 * unit, y: rect.midY + y * unit))
            path.addQuadCurve(to: CGPoint(x: rect.midX + width / 2 * unit, y: rect.midY + y * unit),
                              control: CGPoint(x: rect.midX, y: rect.midY + (y + curve) * unit))
        }
    }
}
