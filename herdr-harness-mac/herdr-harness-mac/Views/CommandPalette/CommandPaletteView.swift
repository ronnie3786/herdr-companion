import SwiftUI

/// Spotlight-style, keyboard-first navigation across every pane in the fleet.
/// The overlay owns only transient query and highlight state; opening a result
/// is handed back to the shell so every route uses the same pane intent.
struct CommandPaletteView: View {
    let entries: [CommandPaletteEntry]
    let focusRequest: Int
    let dismiss: () -> Void
    let select: (CommandPaletteEntry) -> Void

    @State private var state: CommandPaletteState
    @FocusState private var isSearchFocused: Bool

    init(
        entries: [CommandPaletteEntry],
        focusRequest: Int,
        dismiss: @escaping () -> Void,
        select: @escaping (CommandPaletteEntry) -> Void
    ) {
        self.entries = entries
        self.focusRequest = focusRequest
        self.dismiss = dismiss
        self.select = select
        _state = State(initialValue: CommandPaletteState(entries: entries))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: dismiss) {
                Color.clear
            }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.4))
                .contentShape(.rect)
                .focusEffectDisabled()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Label("Open chat", systemImage: "sparkle.magnifyingglass")
                        .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                        .foregroundStyle(HerdrTheme.primaryText)

                    Spacer(minLength: 12)

                    Text("⌘K")
                        .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true, weight: .medium)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HerdrTheme.chipFill, in: .rect(cornerRadius: 4))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: HerdrTheme.ControlHeight.titleBar)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .herdrFont(.body, weight: .bold)
                        .foregroundStyle(isSearchFocused ? HerdrTheme.accent : HerdrTheme.mist)
                        .accessibilityHidden(true)

                    TextField("Search by chat, agent, workspace, tab, or machine", text: $state.query)
                        .textFieldStyle(.plain)
                        .herdrFont(.body)
                        .foregroundStyle(HerdrTheme.text)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .onKeyPress(.downArrow, phases: .down) { _ in
                            state.moveHighlight(by: 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow, phases: .down) { _ in
                            state.moveHighlight(by: -1)
                            return .handled
                        }
                        .onKeyPress(.return, phases: .down) { _ in
                            openHighlightedEntry()
                            return .handled
                        }
                        .onKeyPress(.escape, phases: .down) { _ in
                            dismiss()
                            return .handled
                        }
                        .accessibilityLabel("Search chats")
                        .accessibilityValue(resultSummary)
                        .accessibilityIdentifier("command-palette-search")

                    if !state.query.isEmpty {
                        Button(action: clearQuery) {
                            Image(systemName: "xmark.circle.fill")
                                .herdrHitTarget(minWidth: 32, minHeight: 32)
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(HerdrTheme.mist)
                            .help("Clear search")
                            .accessibilityLabel("Clear search")
                            .accessibilityIdentifier("command-palette-clear")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: HerdrTheme.ControlHeight.bar)
                .background(HerdrTheme.fieldFill)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                        .strokeBorder(isSearchFocused ? HerdrTheme.accent.opacity(0.45) : HerdrTheme.outline, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.Radius.control))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(HerdrTheme.hairline)
                    .frame(height: 1)
                    .accessibilityHidden(true)

                ScrollViewReader { proxy in
                    Group {
                        if state.results.isEmpty {
                            ContentUnavailableView(
                                "No chats found",
                                systemImage: "magnifyingglass",
                                description: Text("Try a title, agent, workspace, tab, or machine name.")
                            )
                            .foregroundStyle(HerdrTheme.mist)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("command-palette-empty")
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(state.results.enumerated()), id: \.element.id) { index, entry in
                                        CommandPaletteRow(
                                            entry: entry,
                                            isHighlighted: index == state.highlightedIndex,
                                            action: { open(entry) },
                                            highlight: { state.highlight(index) }
                                        )
                                        .id(entry.id)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                    }
                    .frame(height: resultsHeight)
                    .onChange(of: state.highlightedEntry?.id) { _, entryID in
                        if let entryID {
                            proxy.scrollTo(entryID, anchor: .center)
                        }
                    }
                }

                Rectangle()
                    .fill(HerdrTheme.hairline)
                    .frame(height: 1)
                    .accessibilityHidden(true)

                HStack(spacing: 12) {
                    Text(resultSummary)
                    Spacer(minLength: 12)
                    Text("↑↓ move   ↩ open   esc close")
                }
                .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: HerdrTheme.ControlHeight.row)
                .accessibilityHidden(true)
            }
            .frame(width: 640)
            .herdrPanel()
            .clipShape(.rect(cornerRadius: HerdrTheme.Radius.panel))
            .shadow(color: Color.black.opacity(0.25), radius: 25, y: 25)
            .padding(.top, 72)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Open chat command palette")
            .accessibilityIdentifier("command-palette")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.query) {
            state.queryDidChange()
        }
        .onChange(of: entries) { _, newEntries in
            state.replaceEntries(newEntries)
        }
        .task(id: focusRequest) {
            await Task.yield()
            isSearchFocused = true
        }
        .onExitCommand(perform: dismiss)
    }

    private var resultSummary: String {
        let count = state.results.count
        return "\(count) \(count == 1 ? "chat" : "chats")"
    }

    private var resultsHeight: Double {
        guard !state.results.isEmpty else { return 150 }
        return min(max(Double(state.results.count) * 58, 58), 406)
    }

    private func clearQuery() {
        state.query = ""
        isSearchFocused = true
    }

    private func openHighlightedEntry() {
        guard let entry = state.highlightedEntry else { return }
        open(entry)
    }

    private func open(_ entry: CommandPaletteEntry) {
        select(entry)
    }
}
