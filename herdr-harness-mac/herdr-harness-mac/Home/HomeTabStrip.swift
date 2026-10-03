import SwiftUI

/// Centered on the entire window, independent of the selected destination's rail.
struct HomeTabStrip: View {
    var selection: HomeTab
    var snapshot: HomeSnapshot
    @Binding var query: String
    @Binding var isSearching: Bool
    var searchFocusRequest = 0
    var hasScrolled = false
    var isActive = true
    var onSelect: (HomeTab) -> Void
    var onSearch: () -> Void
    var chatsTools: AnyView? = nil
    @State private var tabsWidth: CGFloat = 500
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            if hasScrolled {
                LinearGradient(stops: [.init(color: HomePalette.color(0x17161E).opacity(0.95), location: 0),
                                       .init(color: HomePalette.color(0x17161E).opacity(0.95), location: 0.5),
                                       .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 2) {
                ForEach(HomeTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
            .overlay(alignment: .trailing) {
                if let chatsTools { chatsTools.offset(x: 26) }
            }
            .frame(maxWidth: .infinity)
            HStack {
                Spacer(minLength: 0)
                searchControl
                    .offset(y: isSearching && geometry.size.width - tabsWidth < 570 ? 45 : 0)
            }
            .padding(.trailing, 14)
        }
        .frame(height: 64)
        }
        .frame(height: 64)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hasScrolled)
        .onChange(of: searchFocusRequest) { _, _ in
            if selection == .home { isSearching = true; searchFocused = true }
        }
        .onChange(of: isSearching) { _, value in searchFocused = value }
        .onChange(of: searchFocused) { _, value in
            if !value && query.isEmpty { isSearching = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        Button { onSelect(tab) } label: {
            HStack(spacing: 7) {
                if tab == .home {
                    HomeAvatar(mood: snapshot.mood, size: 17, animated: isActive)
                } else {
                    Image(systemName: tab.symbol).font(.system(size: 15))
                }
                Text(tab.title).font(.system(size: 13, weight: selection == tab ? .semibold : .medium))
                if let badge = badge(tab) {
                    Text(badge.text).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(HomePalette.color(badge.tone))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(HomePalette.color(badge.tone).opacity(0.14), in: .capsule)
                }
            }
            .foregroundStyle(selection == tab ? HomePalette.ink : HomePalette.secondary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                if selection == tab {
                    Capsule().fill(HomePalette.accent).frame(height: 2)
                        .shadow(color: HomePalette.accent.opacity(0.4), radius: 5)
                        .padding(.horizontal, 14)
                        .offset(y: 1)
                }
            }
        }
        .buttonStyle(.herdrPlain)
        .accessibilityIdentifier("home-tab-\(tab.rawValue)")
        .accessibilityLabel(tab.title)
        .accessibilityValue(badge(tab).map { "\($0.text) need attention" } ?? "")
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    @ViewBuilder private var searchControl: some View {
        if isSearching && selection == .home {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(HomePalette.icon)
                TextField("Search Home", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("home-search-field")
                    .onExitCommand { query = ""; isSearching = false }
                Button("Close search", systemImage: "xmark") { query = ""; isSearching = false }
                    .labelStyle(.iconOnly).buttonStyle(.herdrPlain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: 230, height: 28)
            .background(.white.opacity(0.04), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? HomePalette.accentLine : HomePalette.border))
        } else {
            Button("Search", systemImage: "magnifyingglass") { onSearch() }
                .labelStyle(.iconOnly)
                .font(.system(size: 16))
                .foregroundStyle(HomePalette.icon)
                .frame(width: 32, height: 32)
                .buttonStyle(.herdrPlain)
                .help(selection == .home ? "Search Home (⌘F)" : "Find in this screen")
                .accessibilityIdentifier("home-search-button")
        }
    }

    private func badge(_ tab: HomeTab) -> (text: String, tone: HomeTone)? {
        switch tab {
        case .home: snapshot.focusCount > 0 ? (String(snapshot.focusCount), .attention) : nil
        case .reviews: snapshot.reviewCount > 0 ? (String(snapshot.reviewCount), snapshot.reviewNeedsAttention ? .alert : .brandBlue) : nil
        case .watchers: snapshot.watcherNeedsAttention ? ("!", .alert) : nil
        case .chats: snapshot.waitingChatCount > 0 ? (String(snapshot.waitingChatCount), .attention) : nil
        }
    }
}
