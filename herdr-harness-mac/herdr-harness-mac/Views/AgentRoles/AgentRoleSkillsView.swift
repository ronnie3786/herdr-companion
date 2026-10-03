import SwiftUI

struct AgentRoleSkillsView: View {
    @Bindable var store: AgentRolesStore
    var showSources: () -> Void = {}
    /// Typing updates only the field; the grid follows after a short pause.
    @State private var query = ""
    private static let topID = "agent-role-skill-grid-top"

    var body: some View {
        let sections = store.skillSections
        let selected = store.selectedIDs
        let sourceNames = Dictionary(store.catalog.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if store.draft?.skillIds == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Automatic skill discovery", systemImage: "sparkles")
                            .herdrFont(.callout, weight: .semibold)
                        Text("This role still uses the execution computer's existing Pi discovery. Configure a selection to allow only the skills you choose from this Mac.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Configure selection", action: store.configureSelection)
                            .disabled(!store.canEdit)
                            .accessibilityIdentifier("agent-role-configure-skills")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { searchField; sourceFilter }
                    VStack(alignment: .leading, spacing: 8) { searchField; sourceFilter }
                }
                if !store.catalog.issues.isEmpty {
                    AgentRoleCatalogNotice(issues: store.catalog.issues, review: showSources)
                } else if let warning = store.catalog.errorMessage {
                    Text(warning).herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)

            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Color.clear.frame(height: 0).id(Self.topID)
                            if !store.missingIDs.isEmpty { AgentRoleMissingSkills(store: store) }
                            ForEach(sections) { section in
                                Section {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                                        ForEach(section.skills) { skill in
                                            AgentRoleSkillTile(skill: skill, sourceName: sourceNames[skill.source] ?? skill.source,
                                                selected: selected.contains(skill.id), enabled: store.canChangeSkills) {
                                                    store.toggleSkill(skill.id)
                                                }
                                        }
                                    }
                                    .padding(.vertical, 10)
                                } header: {
                                    Text(section.id == AgentRoleSkillSearch.matchesID
                                         ? "\(section.skills.count) \(section.skills.count == 1 ? "match" : "matches")"
                                         : section.id)
                                        .herdrFont(.caption, weight: .bold)
                                        .foregroundStyle(HerdrTheme.secondaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8)
                                        .background { HerdrGlassBackground(level: 0.96) }
                                        .id(section.id)
                                        .accessibilityAddTraits(.isHeader)
                                }
                            }
                            if sections.isEmpty {
                                ContentUnavailableView {
                                    Label(store.skills.isEmpty ? "Connect your skill folders" : "No matching skills",
                                          systemImage: store.skills.isEmpty ? "folder.badge.plus" : "magnifyingglass")
                                } description: {
                                    Text(store.skills.isEmpty
                                         ? "macOS needs one-time permission to read skills on this Mac. Your usual skill folders are ready to connect."
                                         : "Try another search or source filter.")
                                } actions: {
                                    if store.skills.isEmpty {
                                        Button("Connect folders…", action: showSources)
                                    }
                                }
                                    .padding(.vertical, 20)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                    .accessibilityIdentifier("agent-role-skill-grid")
                    .onChange(of: store.search) { _, _ in proxy.scrollTo(Self.topID, anchor: .top) }
                    // Ranked search results have no letter sections to jump between.
                    if !store.isSearchingSkills { letterRail(proxy) }
                }
            }
            if store.draft?.skillIds != nil { AgentRoleSkillSelectionBar(store: store) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { query = store.search }
        .task(id: query) {
            guard query != store.search else { return }
            // Clearing is immediate; typing waits for a pause so each keystroke stays responsive.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            store.search = query
        }
        .onChange(of: store.catalog.sources.map(\.id)) { _, ids in
            if !store.sourceFilter.isEmpty, !ids.contains(store.sourceFilter) { store.sourceFilter = "" }
        }
    }

    private func letterRail(_ proxy: ScrollViewProxy) -> some View {
        let letters = Set(store.letters)
        return ScrollView {
            VStack(spacing: 1) {
                ForEach(["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init), id: \.self) { letter in
                    Button(letter) { proxy.scrollTo(letter, anchor: .top) }
                        .buttonStyle(.borderless)
                        .herdrFont(.caption2, weight: .semibold)
                        .foregroundStyle(letters.contains(letter)
                            ? HerdrTheme.secondaryText : HerdrTheme.secondaryText.opacity(0.3))
                        .frame(width: 24, height: 18)
                        .disabled(!letters.contains(letter))
                        .accessibilityLabel("Jump to \(letter)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .frame(width: 28)
        .overlay(alignment: .leading) { Divider() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(HerdrTheme.secondaryText).accessibilityHidden(true)
            TextField("Search skills", text: $query).textFieldStyle(.plain)
                .onSubmit { store.search = query }
                .accessibilityIdentifier("agent-role-skill-search")
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .herdrFont(.callout)
        .padding(8)
        .frame(minWidth: 130)
        .background(HerdrTheme.fieldFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.outline))
    }

    private var sourceFilter: some View {
        Picker("Source", selection: $store.sourceFilter) {
            Text("All sources").tag("")
            ForEach(store.catalog.sources) { source in Text(source.name).tag(source.id) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("agent-role-skill-source-filter")
    }
}
