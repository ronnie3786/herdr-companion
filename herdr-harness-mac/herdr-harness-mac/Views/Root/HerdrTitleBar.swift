import AppKit
import SwiftUI

/// What a detail view puts in the main window's 40pt title bar: its title
/// (and status) on the leading side and its own actions on the trailing side.
/// The shell adds navigation, the scope picker and the global items.
struct HerdrTitleBarItems {
    var leading: AnyView?
    var trailing: AnyView?
}

struct HerdrTitleBarItemsKey: PreferenceKey {
    static var defaultValue: HerdrTitleBarItems? { nil }

    static func reduce(value: inout HerdrTitleBarItems?, nextValue: () -> HerdrTitleBarItems?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// Contributes this screen's title and actions to the window title bar.
    func herdrTitleBar<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        preference(
            key: HerdrTitleBarItemsKey.self,
            value: HerdrTitleBarItems(leading: AnyView(leading()), trailing: AnyView(trailing()))
        )
    }

    /// Contributes only trailing actions; the shell keeps its default title.
    func herdrTitleBarActions<Trailing: View>(@ViewBuilder _ trailing: () -> Trailing) -> some View {
        preference(
            key: HerdrTitleBarItemsKey.self,
            value: HerdrTitleBarItems(leading: nil, trailing: AnyView(trailing()))
        )
    }
}

/// The 40pt bar recipe shared by the window title bar and the sidebar header:
/// horizontal padding, a 7% bottom hairline, and window dragging from any
/// empty part of the bar.
struct HerdrBarBackground: ViewModifier {
    var hairline: Color = HerdrTheme.hairline

    func body(content: Content) -> some View {
        content
            .frame(height: HerdrTheme.ControlHeight.titleBar)
            .frame(maxWidth: .infinity)
            .background { HerdrWindowDragArea() }
            .herdrHairline(.bottom, color: hairline)
    }
}

extension View {
    func herdrBar(hairline: Color = HerdrTheme.hairline) -> some View {
        modifier(HerdrBarBackground(hairline: hairline))
    }
}

/// Empty bar space that moves the window, and zooms or minimizes it on a
/// double click the way the system title bar does.
struct HerdrWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }
}
