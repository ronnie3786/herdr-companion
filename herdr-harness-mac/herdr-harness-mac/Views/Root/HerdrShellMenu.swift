import SwiftUI

/// The app-wide part of the title bar's ⋯ menu: the destinations that used to
/// be segments in the title bar, and Ask Agent. The shell provides it to
/// whatever renders the menu, so a screen with its own ⋯ menu (a chat's pane
/// actions) ends with the same items instead of showing a second menu.
struct HerdrShellMenuActions {
    /// The screen on screen, so its own entry reads as selected.
    var current: HerdrDetailScope?
    var show: (HerdrDetailScope) -> Void
    /// Nil while no machine can be controlled.
    var askAgent: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var herdrShellMenu: HerdrShellMenuActions?
}

/// The shell's sections, for any ⋯ menu inside the main window's title bar.
struct HerdrShellMenuSections: View {
    @Environment(\.herdrShellMenu) private var actions

    var body: some View {
        if let actions {
            Section("Go to") {
                ForEach(destinations(current: actions.current)) { scope in
                    Button {
                        actions.show(scope)
                    } label: {
                        Label(scope.label, systemImage: actions.current == scope ? "checkmark" : scope.symbol)
                    }
                    .accessibilityIdentifier("shell-menu-\(scope.rawValue)")
                }
            }
            Section {
                Button("Ask Agent…", systemImage: "sparkles") { actions.askAgent?() }
                    .disabled(actions.askAgent == nil)
                    .help("Ask a one-off question without creating a chat")
                    .accessibilityIdentifier("open-headless-agent")
            }
        }
    }

    /// A chat's own menu already switches between Chat, Terminal and Git, so
    /// it does not offer Chat again.
    private func destinations(current: HerdrDetailScope?) -> [HerdrDetailScope] {
        HerdrDetailScope.menuDestinations.filter { !(current == .session && $0 == .session) }
    }
}

/// The ⋯ menu for screens without one of their own.
struct HerdrShellMenu: View {
    var tint: Color = HerdrTheme.iconTint

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            HerdrShellMenuSections()
        }
        .herdrIconMenu(tint: tint)
        .help("More")
        .accessibilityIdentifier("shell-more-menu")
    }
}
