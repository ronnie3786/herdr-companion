import SwiftUI

struct WatchersView: View {
    @Bindable var store: WatchersStore
    @State private var filter = "All watchers"
    @State private var search = ""
    @State private var builder = false
    @State private var editor = false
    @State private var selected: WatcherEntry?
    @State private var history: WatcherEntry?
    @State private var inbox = false
    @FocusState private var searchFocused: Bool
    static func columnCount(width: CGFloat) -> Int { width < 650 ? 1 : width < 950 ? 2 : 3 }
    private var filtered: [WatcherEntry] {
        WatchersStore.ordered(store.entries.filter {
            let w = $0.watcher
            let matches = search.isEmpty || (w.name + " " + WatchersSummary.plainText(w.summary, schedule: w.scheduleSummary) + " " + $0.machineName).localizedCaseInsensitiveContains(search)
            return matches && (filter == "All watchers" || filter == "On watch" && w.state == "active" || filter == "Resting" && w.resting || filter == "Scripts only" && w.kind == "script")
        })
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(scroll: scroll)
                        filters
                        if let error = store.error { errorBanner(error) }
                        ForEach(store.notices.keys.sorted(), id: \.self) { key in errorBanner(store.notices[key] ?? "") }
                        if !store.loaded { ProgressView("Finding your watchers…").frame(maxWidth: .infinity).padding(50) }
                        else if store.entries.isEmpty {
                            ContentUnavailableView {
                                Label(store.enabledMachines.isEmpty ? "Watchers needs a companion" : "A little help, on your schedule.", systemImage: "eye")
                            } description: {
                                Text(store.enabledMachines.isEmpty ? "Update a companion with watchers-v1 and enable Watchers to get started." : "Describe what to keep an eye on. Review the draft and next runs before you create it.")
                            }
                        }
                        grid(filtered.filter { !$0.watcher.resting }, width: geometry.size.width)
                        if filtered.contains(where: { $0.watcher.resting }) {
                            HStack { Text("Resting").font(.system(size: 11, weight: .medium)).foregroundStyle(HerdrTheme.secondaryText); Rectangle().fill(HerdrTheme.hairline).frame(height: 1) }
                            grid(filtered.filter { $0.watcher.resting }, width: geometry.size.width)
                        }
                        if !store.entries.isEmpty && filtered.isEmpty { ContentUnavailableView.search(text: search) }
                        Button { selected = nil; builder = true } label: {
                            HStack { Image(systemName: "sparkles"); Text("What would you like someone to keep an eye on?"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 12)).foregroundStyle(HerdrTheme.accent).padding(20).frame(maxWidth: .infinity).background(HerdrTheme.accent.opacity(0.035), in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HerdrTheme.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 5])))
                        }.buttonStyle(.plain).disabled(store.enabledMachines.isEmpty)
                    }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 36)
                }
            }
        }
        .herdrPaneBackground()
        .sheet(isPresented: $builder) { WatcherBuilderSheet(store: store, entry: selected) }
        .sheet(isPresented: $editor) { WatcherEditorSheet(store: store, entry: selected) }
        .sheet(item: $history) { WatcherRunsSheet(store: store, entry: $0) }
        .sheet(isPresented: $inbox) { WatcherInboxSheet(store: store) }
        .background { Button("") { searchFocused = true }.keyboardShortcut("/", modifiers: []).hidden() }
        .accessibilityIdentifier("watchers-destination")
    }
    private func header(scroll: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) { Text("A few extra pairs of eyes.").font(.system(size: 28, weight: .medium)).tracking(-0.9); Text("Meet the watchers keeping an eye on things for you.").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText) }
            Spacer(minLength: 4)
            if let next = store.nextToWake {
                Button { withAnimation { scroll.scrollTo(next.id, anchor: .center) } } label: {
                    HStack(spacing: 10) { WatcherAvatar(avatar: next.watcher.avatar, size: 30); VStack(alignment: .leading, spacing: 4) { Text("Next to wake up").font(.system(size: 9)).foregroundStyle(HerdrTheme.secondaryText); Text(next.watcher.name + " " + (next.watcher.nextFire.map { WatchersDate.relative($0) } ?? "")).font(.system(size: 11)) }; Image(systemName: "play").font(.system(size: 11)).foregroundStyle(HerdrTheme.accent) }.padding(12).background(HerdrTheme.cardFill, in: .rect(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(HerdrTheme.outline))
                }.buttonStyle(.plain).help("Jump to \(next.watcher.name)")
            }
        }
    }
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack { filterButtons; Spacer(); searchField; controls }
            VStack(alignment: .leading, spacing: 12) { filterButtons; HStack { searchField; Spacer(); controls } }
        }
    }
    private var filterButtons: some View {
        HStack(spacing: 3) {
            ForEach(["All watchers", "On watch", "Resting", "Scripts only"], id: \.self) { item in
                Button { filter = item } label: { HStack(spacing: 6) { Text(item); if item == "All watchers" { Text("\(store.entries.count)").foregroundStyle(HerdrTheme.secondaryText) } }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 9).background(filter == item ? HerdrTheme.selectedFill : .clear, in: .rect(cornerRadius: 7)) }.buttonStyle(.plain)
            }
        }
    }
    private var searchField: some View { HStack(spacing: 6) { Image(systemName: "magnifyingglass"); TextField("Find a watcher", text: $search).textFieldStyle(.plain).focused($searchFocused) }.font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText).padding(9).frame(width: 175).background(HerdrTheme.fieldFill, in: .rect(cornerRadius: 7)) }
    private var controls: some View {
        HStack(spacing: 10) {
            Button { inbox = true } label: { Label(store.unreadCount > 0 ? "Inbox \(store.unreadCount)" : "Inbox", systemImage: "tray") }.help("Watcher inbox")
            Menu { Button("Create with an agent") { selected = nil; builder = true }; Button("Set up manually") { selected = nil; editor = true } } label: { Label("New watcher", systemImage: "plus") }.disabled(store.enabledMachines.isEmpty)
        }.font(.system(size: 11)).buttonStyle(.bordered)
    }
    private func grid(_ entries: [WatcherEntry], width: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 19), count: Self.columnCount(width: width)), alignment: .leading, spacing: 19) {
            ForEach(entries) { entry in
                WatcherCard(entry: entry, busy: store.busy.contains(entry.id) || store.demo || !store.enabledMachines.contains(entry.machineID), edit: { selected = entry; editor = true }, action: { action in Task { await store.action(action, entry: entry) } }, history: { history = entry }, build: { selected = entry; builder = true }).id(entry.id)
            }
        }
    }
    private func errorBanner(_ text: String) -> some View { Label(text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(HerdrTheme.insetFill, in: .rect(cornerRadius: 8)) }
}
