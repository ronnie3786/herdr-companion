import SwiftUI

/// The inspector column (MonoCode's `.fm-insp`): underline tabs, a scrolling
/// body, and a 32pt sync footer.
struct FirstMateInspectorView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HerdrTabs(
                    selection: $store.inspector,
                    tabs: FirstMateInspector.allCases.map {
                        .init(value: $0, title: $0.rawValue, accessibilityIdentifier: "first-mate-tab-\($0.id)")
                    },
                    style: .underline,
                    accessibilityLabel: "Inspector"
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: HerdrTheme.ControlHeight.bar)
            .herdrHairline(.bottom, color: palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch store.inspector {
                    case .overview: FirstMateOverviewView(store: store, snapshot: snapshot)
                    case .agents: FirstMateAgentsView(store: store, snapshot: snapshot)
                    case .documents: FirstMateDocumentsView(store: store, snapshot: snapshot)
                    case .workflow: FirstMateWorkflowView(store: store, snapshot: snapshot)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Image(systemName: store.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                    .herdrFont(size: 12)
                    .foregroundStyle(palette.iconTint)
                    .accessibilityHidden(true)
                Text(store.isDemo ? "Synthetic data · no agents launched" : store.error == nil ? "Synced with companion" : "Connection needs attention")
                    .lineLimit(1)
                Spacer()
                Text("Revision \(snapshot.feature.revision)")
                    .monospacedDigit()
            }
            .herdrFont(size: HerdrTheme.TextSize.caption)
            .foregroundStyle(palette.tertiaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: HerdrTheme.ControlHeight.row)
            .herdrHairline(.top, color: palette.hairline)
        }
        .herdrPaneBackground(palette.background)
        .herdrHairline(.leading, color: palette.hairline)
    }
}
