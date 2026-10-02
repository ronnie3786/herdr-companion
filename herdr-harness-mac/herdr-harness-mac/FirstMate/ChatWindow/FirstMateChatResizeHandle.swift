import SwiftUI

/// A split divider with drag, keyboard, and VoiceOver resizing. A compact
/// focus marker replaces the native ring, which outlines the entire tall
/// hit area as two persistent bright lines after the divider is clicked.
struct FirstMateChatResizeHandle: View {
    let displayedWidth: CGFloat
    /// +1 for the leading column, -1 for the trailing column.
    let widthDirection: CGFloat
    let label: String
    let value: String
    let identifier: String
    let help: String
    let onResize: (CGFloat, Bool) -> Void
    let onStep: (CGFloat) -> Void
    @State private var dragStartWidth: CGFloat?
    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .overlay {
                if isFocused, controlActiveState == .key {
                    Capsule()
                        .fill(HerdrTheme.accent)
                        .frame(width: 3, height: 28)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { event in
                        if dragStartWidth == nil { dragStartWidth = displayedWidth }
                        onResize(proposedWidth(translation: event.translation.width), false)
                    }
                    .onEnded { event in
                        onResize(proposedWidth(translation: event.translation.width), true)
                        dragStartWidth = nil
                    }
            )
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-20 * widthDirection) }
            .onKeyPress(.rightArrow) { step(20 * widthDirection) }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onStep(20)
                case .decrement: onStep(-20)
                @unknown default: break
                }
            }
            .accessibilityIdentifier(identifier)
            .help(help)
    }

    private func proposedWidth(translation: CGFloat) -> CGFloat {
        (dragStartWidth ?? displayedWidth) + translation * widthDirection
    }

    private func step(_ amount: CGFloat) -> KeyPress.Result {
        onStep(amount)
        return .handled
    }
}
