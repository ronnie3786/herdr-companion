import SwiftUI

/// Render-only Home. Its caller owns source observation, selection and commands.
struct HomeContentView: View {
    var snapshot: HomeSnapshot
    var selectedFocusID: String?
    @Binding var recapExpanded: Bool
    var onSelectFocus: (String) -> Void
    var onCommand: (HomeCommand) -> Void
    var onScroll: (Bool) -> Void = { _ in }
    var isVisible = true

    var body: some View {
        GeometryReader { geometry in
            let grid = HomeGeometry.grid(width: geometry.size.width)
            ScrollView {
                HStack(alignment: .top, spacing: grid.gap) {
                    HomeFirstMateColumn(snapshot: snapshot, isVisible: isVisible, onCommand: onCommand)
                        .frame(width: grid.column)
                        .padding(.top, 10)
                    VStack(alignment: .leading, spacing: 0) {
                        HomeSummaryBalloon(snapshot: snapshot, onCommand: onCommand)
                        if !snapshot.focus.isEmpty {
                            HomeFocusStack(items: snapshot.focus, selectedID: selectedFocusID,
                                           onSelect: onSelectFocus, onCommand: onCommand)
                                .padding(.top, 26)
                        } else if snapshot.canShowAllClear {
                            HomeAllClearCard(onCommand: onCommand).padding(.top, 26)
                        }
                        if !snapshot.chats.isEmpty {
                            HomeWaitingChats(title: snapshot.chatsTitle, items: snapshot.chats, onCommand: onCommand)
                                .padding(.top, 30)
                        }
                        if !snapshot.recap.isEmpty {
                            HomeRecap(title: snapshot.recapTitle, items: snapshot.recap,
                                      isExpanded: $recapExpanded, onCommand: onCommand)
                                .padding(.top, 26)
                        }
                    }
                    .frame(width: grid.content)
                }
                .frame(width: grid.width, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, HomeGeometry.topInset)
                .padding(.bottom, HomeGeometry.bottomInset)
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 6 } action: { _, scrolled in
                onScroll(scrolled)
            }
        }
        .background(HomeBackground())
        .tint(HomePalette.accent)
        .accessibilityIdentifier("home.content")
    }
}
