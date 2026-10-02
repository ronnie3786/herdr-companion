import SwiftUI

/// The iPad chat bar's column controls: the list toggle on the leading edge
/// and the inspector toggle on the trailing edge. Absent on iPhone, where the
/// bar shows Back and an Info button that pushes Info instead.
struct FirstMateRegularChatControls {
    var listIsRail: Bool
    var toggleList: () -> Void
    var inspectorOpen: Bool
    var toggleInspector: () -> Void
    /// Opens the inspector on a tab without toggling it closed.
    var showInspector: (FirstMateInspector) -> Void
}

/// The iPad inspector panel's own buttons beside its tabs: Close while it
/// floats over the chat, and Pin on portrait iPads wide enough to dock it.
struct FirstMateInspectorPanelControls {
    var isFloating: Bool
    var canPin: Bool
    var isPinned: Bool
    var togglePin: () -> Void
    var close: () -> Void
}

extension EnvironmentValues {
    @Entry var firstMateRegularChatControls: FirstMateRegularChatControls? = nil
    @Entry var firstMateInspectorPanelControls: FirstMateInspectorPanelControls? = nil
}

/// Pin and Close for a floating or pinned inspector, trailing its tab bar.
struct FirstMateInspectorPanelButtons: View {
    @Environment(\.firstMateInspectorPanelControls) private var controls

    var body: some View {
        if let controls, controls.isFloating || controls.isPinned {
            HStack(spacing: 2) {
                if controls.canPin {
                    Button(action: controls.togglePin) {
                        Image(systemName: controls.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(controls.isPinned ? HerdrTheme.accent : HerdrTheme.secondaryText)
                            .frame(width: 36, height: 36)
                            .background(controls.isPinned ? HerdrTheme.accent.opacity(0.18) : HerdrTheme.inkFill(0.06), in: .circle)
                            .frame(width: 44, height: 44).contentShape(.rect)
                    }
                    .accessibilityLabel(controls.isPinned ? "Float the inspector over the chat" : "Dock the inspector beside the chat")
                    .accessibilityIdentifier("first-mate-inspector-pin")
                }
                if controls.isFloating {
                    Button(action: controls.close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(HerdrTheme.secondaryText)
                            .frame(width: 36, height: 36)
                            .background(HerdrTheme.inkFill(0.06), in: .circle)
                            .frame(width: 44, height: 44).contentShape(.rect)
                    }
                    .accessibilityLabel("Close the inspector")
                    .accessibilityIdentifier("first-mate-inspector-close")
                }
            }
            .buttonStyle(.herdrPlain)
        }
    }
}
