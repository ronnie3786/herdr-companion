import SwiftUI

struct FirstMateInspectorTabs: View {
    @Bindable var store: FirstMateStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(FirstMateInspector.allCases) { tab in
                        Button { store.inspector = tab } label: {
                            Label(tab.rawValue, systemImage: tab.symbol)
                                .font(.subheadline.weight(store.inspector == tab ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .foregroundStyle(store.inspector == tab ? FirstMatePalette(scheme: scheme).accent : FirstMatePalette(scheme: scheme).secondaryText)
                                .background(store.inspector == tab ? FirstMatePalette(scheme: scheme).accent.opacity(0.12) : .clear, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .id(tab)
                        .accessibilityAddTraits(store.inspector == tab ? .isSelected : [])
                        .accessibilityIdentifier("first-mate-tab-\(tab.id)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(store.inspector, anchor: .center) }
            .onChange(of: store.inspector) { _, tab in proxy.scrollTo(tab, anchor: .center) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
