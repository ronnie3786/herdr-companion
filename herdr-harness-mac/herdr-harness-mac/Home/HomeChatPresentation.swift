import AppKit
import SwiftUI

/// Mount on the four-tab shell. The controller outlives this presentation;
/// closing the tray or leaving Home preserves its draft and outgoing state.
struct HomeChatPresentation: ViewModifier {
    @Bindable var controller: HomeChatController
    let model: HerdrAppModel
    let modelFavorites: ModelFavoritesStore
    let snapshot: HomeSnapshot
    let isHomeVisible: Bool
    let isActive: Bool
    @Binding var query: String
    @Binding var searchPresented: Bool
    let askRequest: Int
    let openWindow: () -> Void

    @FocusState private var askBarFocused: Bool
    @State private var composerFocusRequest = 0
    @State private var focusReturn = HomeChatFocusReturn()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    if isHomeVisible {
                        presentation(size: geometry.size)
                    }
                }
            }
            .background {
                HomeChatEscapeMonitor(isEnabled: isHomeVisible && isActive,
                                      focusReturn: focusReturn, onEscape: escape)
            }
            .onChange(of: askRequest) { _, _ in
                if isHomeVisible { present() }
            }
            .onChange(of: controller.isPresented) { _, presented in
                if presented {
                    focusReturn.captureIfNeeded()
                    askBarFocused = false
                } else if isHomeVisible, isActive {
                    restoreFocus()
                }
            }
            .onChange(of: isHomeVisible) { _, visible in
                if !visible {
                    controller.dismiss()
                    focusReturn.clear()
                    askBarFocused = false
                }
            }
            .onDisappear {
                controller.dismiss()
                focusReturn.clear()
            }
    }

    private func presentation(size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            askBar
                .frame(width: HomeChatPresentationLayout.askWidth(in: size.width), height: 50)
                .padding(.bottom, 22)
                .opacity(controller.isPresented ? 0 : 1)
                .allowsHitTesting(!controller.isPresented)
                .accessibilityHidden(controller.isPresented)
            if controller.isPresented {
                Color.black.opacity(reduceTransparency ? 0.48 : 0.34)
                    .contentShape(.rect)
                    .onTapGesture(perform: close)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                HomeChatTrayView(controller: controller, model: model, modelFavorites: modelFavorites,
                                 homeSnapshot: snapshot, openWindow: openWindow, close: close,
                                 isActive: isActive, focusRequest: composerFocusRequest)
                    .frame(width: HomeChatPresentationLayout.traySize(in: size).width,
                           height: HomeChatPresentationLayout.traySize(in: size).height)
                    .padding(.bottom, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: controller.isPresented)
    }

    private var askBar: some View {
        Button(action: present) {
            HStack(spacing: 11) {
                HomeAvatar(mood: snapshot.mood, size: 27, animated: isActive)
                    .accessibilityHidden(true)
                Text("Ask First Mate…")
                    .font(.system(size: 14))
                    .foregroundStyle(HomePalette.prose)
                Spacer(minLength: 8)
                Text("⌘J")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(HomePalette.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.white.opacity(0.04), in: .rect(cornerRadius: 4))
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.07), lineWidth: 1) }
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HomePalette.color(0x25242D), in: .capsule)
            .overlay { Capsule().strokeBorder(askBarFocused ? HomePalette.accent : .white.opacity(0.13), lineWidth: askBarFocused ? 2 : 1) }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.herdrPlain)
        .focusable()
        .focused($askBarFocused)
        .accessibilityLabel("Ask First Mate")
        .accessibilityHint("Opens your lead conversation. Messages send only when you press Send.")
        .accessibilityIdentifier("home-ask-bar")
    }

    private func present() {
        if !controller.isPresented {
            focusReturn.captureIfNeeded()
            let context = controller.contexts.isEmpty && controller.draft.isEmpty
                ? HomeActionContext.make(route: nil, snapshot: snapshot) : nil
            controller.open(context: context)
        }
        askBarFocused = false
        composerFocusRequest &+= 1
    }

    private func close() {
        controller.dismiss()
    }

    /// Search takes precedence even when the composer has the keyboard.
    /// This handler only observes the window containing this Home surface.
    private func escape() -> Bool {
        if searchPresented {
            query = ""
            searchPresented = false
            if controller.isPresented { composerFocusRequest &+= 1 }
            else { askBarFocused = true }
            return true
        }
        guard controller.isPresented else { return false }
        close()
        return true
    }

    private func restoreFocus() {
        guard focusReturn.isKeyWindow else { focusReturn.clear(); return }
        if !focusReturn.restore() { askBarFocused = true }
    }
}

/// Measurements stay in window coordinates, including at the supported
/// minimum and when a full-screen window grows beyond the reference size.
enum HomeChatPresentationLayout {
    static func askWidth(in width: CGFloat) -> CGFloat { min(448, max(1, width - 64)) }
    static func traySize(in size: CGSize) -> CGSize {
        CGSize(width: min(574, max(1, size.width - 48)),
               height: min(700, max(1, size.height * 0.78)))
    }
}

@MainActor
private final class HomeChatFocusReturn {
    weak var marker: NSView?
    private weak var responder: NSResponder?
    private weak var capturedWindow: NSWindow?
    private var captured = false

    var isKeyWindow: Bool { marker?.window?.isKeyWindow == true }

    func captureIfNeeded() {
        guard !captured, let window = marker?.window else { return }
        captured = true
        capturedWindow = window
        responder = window.firstResponder
    }

    func restore() -> Bool {
        defer { clear() }
        guard let window = marker?.window, window.isKeyWindow, window === capturedWindow,
              let view = responder as? NSView, view.window === window,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        return window.makeFirstResponder(view)
    }

    func clear() {
        captured = false
        capturedWindow = nil
        responder = nil
    }
}

private struct HomeChatEscapeMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let focusReturn: HomeChatFocusReturn
    let onEscape: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onEscape: onEscape) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.isEnabled = isEnabled
        focusReturn.marker = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }
            return coordinator.handle(event)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onEscape = onEscape
        focusReturn.marker = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var isEnabled = true
        var onEscape: () -> Bool

        init(onEscape: @escaping () -> Bool) { self.onEscape = onEscape }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  let view, !view.isHiddenOrHasHiddenAncestor, let window = view.window,
                  window.isKeyWindow, event.window === window, window.attachedSheet == nil else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            return onEscape() ? nil : event
        }
    }
}
