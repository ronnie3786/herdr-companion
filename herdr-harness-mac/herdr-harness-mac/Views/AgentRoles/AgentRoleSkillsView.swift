import SwiftUI

struct AgentRoleSkillsView: View {
    @Bindable var store: AgentRolesStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if store.draft?.skillIds == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Automatic skill discovery", systemImage: "sparkles")
                            .herdrFont(.callout, weight: .semibold)
                        Text("This role still uses the execution computer's existing Pi discovery. Configure a selection to allow only the skills you choose from this Mac.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
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
                if let warning = store.catalog.errorMessage {
                    Text(warning).herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                        .lineLimit(3).help(warning)
                }
                if let warnings = store.overview?.warnings, !warnings.isEmpty {
                    Text(warnings.joined(separator: "\n"))
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                        .lineLimit(3).help(warnings.joined(separator: "\n"))
                }
            }
            .padding(14)

            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if !store.missingIDs.isEmpty { AgentRoleMissingSkills(store: store) }
                            ForEach(store.letters, id: \.self) { letter in
                                Section {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                                        ForEach(store.filteredSkills.filter { $0.letter == letter }) { skill in
                                            AgentRoleSkillTile(skill: skill, sourceName: store.sourceName(skill.source),
                                                selected: store.selectedIDs.contains(skill.id), enabled: store.canChangeSkills) {
                                                    store.toggleSkill(skill.id)
                                                }
                                        }
                                    }
                                    .padding(.vertical, 10)
                                } header: {
                                    Text(letter)
                                        .herdrFont(.caption, weight: .bold)
                                        .foregroundStyle(HerdrTheme.secondaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8)
                                        .background(HerdrTheme.railBackground)
                                        .id(letter)
                                        .accessibilityAddTraits(.isHeader)
                                }
                            }
                            if store.filteredSkills.isEmpty {
                                ContentUnavailableView(
                                    store.skills.isEmpty ? "No local skills yet" : "No matching skills",
                                    systemImage: store.skills.isEmpty ? "folder" : "magnifyingglass",
                                    description: Text(store.skills.isEmpty
                                        ? "Use Skills from this Mac to choose a skill folder or grant access."
                                        : "Try another search or source filter."))
                                    .padding(.vertical, 20)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                    .accessibilityIdentifier("agent-role-skill-grid")
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init), id: \.self) { letter in
                                Button(letter) { proxy.scrollTo(letter, anchor: .top) }
                                    .buttonStyle(.borderless)
                                    .herdrFont(.caption2, weight: .semibold)
                                    .frame(width: 24, height: 18)
                                    .disabled(!store.letters.contains(letter))
                                    .accessibilityLabel("Jump to \(letter)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: 28)
                    .overlay(alignment: .leading) { Divider() }
                }
            }
            if store.draft?.skillIds != nil { AgentRoleSkillSelectionBar(store: store) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.catalog.sources.map(\.id)) { _, ids in
            if !store.sourceFilter.isEmpty, !ids.contains(store.sourceFilter) { store.sourceFilter = "" }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(HerdrTheme.secondaryText).accessibilityHidden(true)
            TextField("Search skills", text: $store.search).textFieldStyle(.plain)
                .accessibilityIdentifier("agent-role-skill-search")
            if !store.search.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { store.search = "" }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .herdrFont(.callout)
        .padding(8)
        .frame(minWidth: 130)
        .background(HerdrTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
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
