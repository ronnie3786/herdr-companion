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
    static func columnCount(width: CGFloat) -> Int { WatchersMetrics.forWidth(width).columns }
    private var filtered: [WatcherEntry] {
        WatchersStore.ordered(store.entries.filter {
            let w = $0.watcher
            let matches = search.isEmpty || (w.name + " " + WatchersSummary.plainText(w.summary, schedule: w.scheduleSummary) + " " + $0.machineName).localizedCaseInsensitiveContains(search)
            return matches && (filter == "All watchers" || filter == "On watch" && w.state == "active" || filter == "Resting" && w.resting || filter == "Scripts only" && w.kind == "script")
        })
    }
    var body: some View {
        GeometryReader { geometry in
            let metrics = WatchersMetrics.forWidth(geometry.size.width)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        intro(scroll: scroll, metrics: metrics).padding(.bottom, metrics.stacksIntro ? 22 : 29)
                        toolbar(metrics).padding(.bottom, 20)
                        VStack(alignment: .leading, spacing: 12) {
                            if let error = store.error { errorBanner(error) }
                            ForEach(store.notices.keys.sorted(), id: \.self) { key in errorBanner(store.notices[key] ?? "") }
                        }
                        .padding(.bottom, store.error == nil && store.notices.isEmpty ? 0 : 20)
                        content(metrics)
                        createPrompt.padding(.top, 24)
                    }
                    .padding(.horizontal, metrics.contentSide).padding(.top, metrics.contentTop).padding(.bottom, metrics.contentBottom + 16)
                }
            }
        }
        .herdrPaneBackground()
        .herdrTitleBarActions { titleActions }
        .sheet(isPresented: $builder) { WatcherBuilderSheet(store: store, entry: selected) }
        .sheet(isPresented: $editor) { WatcherEditorSheet(store: store, entry: selected) }
        .sheet(item: $history) { WatcherRunsSheet(store: store, entry: $0) }
        .sheet(isPresented: $inbox) { WatcherInboxSheet(store: store) }
        .background { Button("") { searchFocused = true }.keyboardShortcut("/", modifiers: []).hidden() }
        .accessibilityIdentifier("watchers-destination")
    }
    @ViewBuilder private func content(_ metrics: WatchersMetrics) -> some View {
        if !store.loaded { ProgressView("Finding your watchers…").frame(maxWidth: .infinity).padding(50) }
        else if store.entries.isEmpty {
            ContentUnavailableView {
                Label(store.enabledMachines.isEmpty ? "Watchers needs a companion" : "A little help, on your schedule.", systemImage: "eye")
            } description: {
                Text(store.enabledMachines.isEmpty ? "Update a companion with watchers-v1 and enable Watchers to get started." : "Describe what to keep an eye on. Review the draft and next runs before you create it.")
            }
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Text("No watchers here yet.").font(.system(size: 13)).foregroundStyle(HerdrTheme.secondaryText)
                Text("Try another filter or describe a new watcher.").font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 65).padding(.horizontal, 20)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HerdrTheme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        } else {
            let awake = filtered.filter { !$0.watcher.resting }, asleep = filtered.filter { $0.watcher.resting }
            VStack(alignment: .leading, spacing: 0) {
                grid(awake, metrics: metrics)
                if !awake.isEmpty && !asleep.isEmpty {
                    HStack(spacing: 8) { Text("Resting").font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText); Rectangle().fill(HerdrTheme.hairline).frame(height: 1) }
                        .padding(.top, metrics.gap + 6).padding(.bottom, metrics.gap - 4)
                }
                grid(asleep, metrics: metrics)
            }
        }
    }
    private func intro(scroll: ScrollViewProxy, metrics: WatchersMetrics) -> some View {
        let layout = metrics.stacksIntro ? AnyLayout(VStackLayout(alignment: .leading, spacing: 19)) : AnyLayout(HStackLayout(alignment: .center, spacing: 24))
        return layout {
            VStack(alignment: .leading, spacing: 8) {
                Text("A few extra pairs of eyes.").font(.system(size: metrics.title, weight: .medium)).tracking(-0.9).foregroundStyle(HerdrTheme.primaryText).watchersLineHeight(metrics.title, 1.3)
                Text("Meet the watchers keeping an eye on things for you.").font(.system(size: metrics.intro)).foregroundStyle(HerdrTheme.secondaryText).watchersLineHeight(metrics.intro, 1.7)
            }
            if !metrics.stacksIntro { Spacer(minLength: 0) }
            if !store.entries.isEmpty { nextPill(scroll: scroll, stretches: metrics.stacksIntro) }
        }
    }
    /// The soonest watcher to wake, or the one working now; it jumps to that card.
    private func nextPill(scroll: ScrollViewProxy, stretches: Bool) -> some View {
        let working = store.entries.first { $0.watcher.live != nil }
        let target = working ?? store.nextToWake
        return Button { if let target { withAnimation { scroll.scrollTo(target.id, anchor: .center) } } } label: {
            HStack(spacing: 10) {
                if let target { WatcherAvatar(avatar: target.watcher.avatar, working: working != nil, size: 30).padding(.trailing, 2) }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(working != nil ? "Working now" : "Next to wake up").font(.system(size: 9)).foregroundStyle(HerdrTheme.secondaryText)
                        Text(target.map { $0.watcher.name + (working != nil ? "" : $0.watcher.nextFire.map { " " + WatchersDate.relative($0, now: context.date) } ?? "") } ?? "Nothing scheduled")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(WatchersStyle.hex(0xCCC7E3)).lineLimit(1)
                    }
                }
                if stretches { Spacer(minLength: 0) }
                if working == nil && target != nil { Image(systemName: "play").font(.system(size: 10.5)).foregroundStyle(HerdrTheme.accent).padding(.leading, 7) }
            }
            .padding(.vertical, 10).padding(.horizontal, 13)
            .frame(maxWidth: stretches ? .infinity : 255, alignment: .leading).fixedSize(horizontal: !stretches, vertical: false)
            .background(HerdrTheme.accent.opacity(0.03), in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(HerdrTheme.accent.opacity(0.13), lineWidth: 1))
        }
        .buttonStyle(.herdrPlain).disabled(target == nil).help(target.map { "Jump to \($0.watcher.name)" } ?? "")
    }
    @ViewBuilder private func toolbar(_ metrics: WatchersMetrics) -> some View {
        if metrics.columns == 1 {
            VStack(alignment: .leading, spacing: 13) { filterButtons; searchField.frame(maxWidth: .infinity) }
        } else {
            HStack(spacing: 20) { filterButtons; Spacer(minLength: 0); searchField.frame(width: 179) }
        }
    }
    private var filterButtons: some View {
        HStack(spacing: 6) {
            ForEach(["All watchers", "On watch", "Resting", "Scripts only"], id: \.self) { item in
                Button { filter = item } label: {
                    HStack(spacing: 5) { Text(item); if item == "All watchers" { Text("\(store.entries.count)").font(.system(size: 9)).foregroundStyle(HerdrTheme.secondaryText).monospacedDigit() } }
                        .font(.system(size: 11)).foregroundStyle(filter == item ? HerdrTheme.primaryText : HerdrTheme.secondaryText)
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(filter == item ? HerdrTheme.inkFill(0.027) : .clear, in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filter == item ? HerdrTheme.inkFill(0.04) : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.herdrPlain).accessibilityAddTraits(filter == item ? .isSelected : [])
            }
        }
        .fixedSize()
    }
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(HerdrTheme.secondaryText)
            TextField("Find a watcher", text: $search).textFieldStyle(.plain).font(.system(size: 10.5)).focused($searchFocused)
        }
        .padding(.vertical, 8).padding(.horizontal, 9)
        .background(HerdrTheme.inkFill(0.008), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? HerdrTheme.accent : HerdrTheme.hairline, lineWidth: 1))
    }
    /// Inbox and New watcher live in the title bar, like the prototype's toolbar.
    private var titleActions: some View {
        HStack(spacing: 8) {
            Button { inbox = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                    Text("Inbox")
                    if store.unreadCount > 0 { Text("\(store.unreadCount)").font(.system(size: 10, weight: .semibold)).foregroundStyle(HerdrTheme.onBadge).padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(HerdrTheme.badgeFill, in: .capsule) }
                }
            }
            .buttonStyle(HerdrButtonStyle(kind: .ghost, height: HerdrTheme.ControlHeight.regular)).help("Watcher inbox")
            Menu {
                Button("Create with an agent") { selected = nil; builder = true }
                Button("Set up manually") { selected = nil; editor = true }
            } label: { Label("New watcher", systemImage: "plus") }
                .menuStyle(.button).buttonStyle(HerdrButtonStyle(kind: .primary, height: HerdrTheme.ControlHeight.regular)).menuIndicator(.hidden).fixedSize()
                .disabled(store.enabledMachines.isEmpty)
        }
    }
    private var createPrompt: some View {
        Button { selected = nil; builder = true } label: {
            HStack(spacing: 15) {
                Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(HerdrTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("What would you like someone to keep an eye on?").font(.system(size: 12, weight: .medium)).foregroundStyle(WatchersStyle.hex(0xCEC7E2))
                    Text("Describe it in a sentence. Give your next watcher a job.").font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(HerdrTheme.accent)
            }
            .padding(.vertical, 19).padding(.horizontal, 22).frame(maxWidth: .infinity)
            .background(HerdrTheme.accent.opacity(0.016), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.accent.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.herdrPlain).disabled(store.enabledMachines.isEmpty)
    }
    /// Rows stretch every card to the tallest, as the prototype's CSS grid does.
    @ViewBuilder private func grid(_ entries: [WatcherEntry], metrics: WatchersMetrics) -> some View {
        let columns = metrics.columns
        Grid(horizontalSpacing: metrics.gap, verticalSpacing: metrics.gap) {
            ForEach(Array(stride(from: 0, to: entries.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(entries[start..<min(start + columns, entries.count)]) { entry in
                        WatcherCard(entry: entry, busy: store.busy.contains(entry.id) || store.demo || !store.enabledMachines.contains(entry.machineID), metrics: metrics, edit: { selected = entry; editor = true }, action: { action in Task { await store.action(action, entry: entry) } }, history: { history = entry }, build: { selected = entry; builder = true })
                            .id(entry.id)
                    }
                    ForEach(0..<(columns - min(columns, entries.count - start)), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
    }
    private func errorBanner(_ text: String) -> some View { Label(text, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(HerdrTheme.insetFill, in: .rect(cornerRadius: 8)) }
}
