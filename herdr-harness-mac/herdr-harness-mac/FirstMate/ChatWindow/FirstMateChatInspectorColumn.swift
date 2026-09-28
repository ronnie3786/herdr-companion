import SwiftUI

/// The chat window's inspector: the native `FirstMateInspectorView`, bound to
/// the window's own store, for a feature; an Overview of every feature for My
/// First Mate.
///
/// `topInset` is empty, draggable space above the tab bar, so the tab bar's
/// bottom edge lines up with the chat header's when the inspector is a column.
struct FirstMateChatInspectorColumn: View {
    let session: FirstMateChatWindowSession
    var topInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if topInset > 0 {
                HerdrWindowDragArea()
                    .frame(height: topInset)
                    .frame(maxWidth: .infinity)
                    .herdrHairline(.leading)
                    .accessibilityHidden(true)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    @ViewBuilder private var content: some View {
        switch session.selection {
        case .lead:
            FirstMateLeadOverviewView(session: session)
        case .feature:
            if let store = session.selectedStore, let snapshot = session.selectedSnapshot {
                FirstMateChatFeatureInspector(store: store, snapshot: snapshot)
            } else {
                FirstMateInspectorPlaceholder(error: session.selectedStore?.error)
            }
        }
    }
}

/// The native inspector with the styling and sheets `FirstMateWorkspaceView`
/// gives it, so document and session opens work here too.
private struct FirstMateChatFeatureInspector: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        FirstMateInspectorView(store: store, snapshot: snapshot)
            .foregroundStyle(palette.text, palette.secondaryText, palette.tertiaryText)
            .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.regular))
            .tint(palette.accent)
            .sheet(item: $store.resourcePresentation, onDismiss: store.closeResource) { _ in
                if let resource = store.openedResource {
                    FirstMateResourceSheet(store: store, resource: resource)
                        .id(resource.id)
                }
            }
    }
}

/// A selected chat whose snapshot has not arrived yet: a quiet progress
/// indicator, or the store's error.
private struct FirstMateInspectorPlaceholder: View {
    let error: String?

    var body: some View {
        VStack(spacing: 10) {
            if let error {
                Image(systemName: "exclamationmark.circle")
                    .herdrFont(size: 18)
                    .foregroundStyle(HerdrTheme.iconTint)
                Text(error)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Loading the feature…")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .herdrHairline(.leading)
    }
}
