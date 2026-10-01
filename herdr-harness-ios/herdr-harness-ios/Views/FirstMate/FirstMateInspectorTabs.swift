import SwiftUI

struct FirstMateInspectorTabs: View {
    @Bindable var store: FirstMateStore

    // The order is shared with the desktop inspector, independent of the enum's
    // historical declaration order.
    private let tabs: [FirstMateInspector] = [.overview, .agents, .documents, .workflow]

    var body: some View {
        HStack(spacing: 8) {
            HerdrTabs(selection: $store.inspector, tabs: tabs.map {
                .init(value: $0, title: $0.rawValue, accessibilityIdentifier: "first-mate-tab-\($0.id)")
            }, style: .underline, accessibilityLabel: "Feature info tabs")
            Spacer(minLength: 0)
            FirstMateInspectorPanelButtons()
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .herdrHairline(.bottom)
        .accessibilityIdentifier("first-mate-info-tabs")
    }
}
