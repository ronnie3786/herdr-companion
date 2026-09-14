import AppKit
import SwiftUI

struct HerdrHudChatResizeHandle: View {
    let controller: HerdrHudController
    @State private var startingSize: CGSize?
    @State private var mouseOrigin: CGPoint?

    var body: some View {
        Label("Resize", systemImage: "arrow.up.right.and.arrow.down.left")
            .herdrFont(.caption2)
            .foregroundStyle(HerdrTheme.muted)
            .padding(.horizontal, 10)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let mouse = NSEvent.mouseLocation
                        if startingSize == nil {
                            startingSize = controller.chatCardSize
                            mouseOrigin = CGPoint(x: mouse.x - value.translation.width,
                                                  y: mouse.y + value.translation.height)
                        }
                        guard let size = startingSize, let origin = mouseOrigin else { return }
                        // The HUD grows left/down from its top-right anchor. Use
                        // screen coordinates, not the moving panel's local frame.
                        controller.resizeChat(to: CGSize(width: size.width - (mouse.x - origin.x),
                                                         height: size.height - (mouse.y - origin.y)))
                    }
                    .onEnded { _ in
                        startingSize = nil
                        mouseOrigin = nil
                    }
            )
            .contextMenu {
                Button("Larger chat") { adjust(by: 40) }
                Button("Smaller chat") { adjust(by: -40) }
                Button("Reset chat size", action: controller.resetChatSize)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize HUD chat")
            .accessibilityValue("\(Int(controller.chatCardSize.width)) by \(Int(controller.chatCardSize.height)) points")
            .accessibilityAdjustableAction { direction in adjust(by: direction == .increment ? 40 : -40) }
            .accessibilityIdentifier("hud-chat-resize")
            .help("Drag left or down to enlarge the chat. Right-click for size controls or reset.")
    }

    private func adjust(by amount: CGFloat) {
        controller.resizeChat(to: CGSize(width: controller.chatCardSize.width + amount,
                                         height: controller.chatCardSize.height + amount))
    }
}
