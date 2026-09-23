import SwiftUI

struct AgentProfilesSidebarView: View {
    @Bindable var store: AgentProfilesStore
    let selectProfile: (String) -> Void
    let createProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profiles")
                    .herdrFont(.headline, weight: .semibold)
                Spacer()
                Button("New profile", systemImage: "plus", action: createProfile)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("New profile")
                    .accessibilityIdentifier("agent-profiles-new")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.overview?.profiles ?? []) { profile in
                        Button {
                            selectProfile(profile.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: store.selectedProfileID == profile.id ? "person.crop.circle.fill" : "person.crop.circle")
                                    .foregroundStyle(store.selectedProfileID == profile.id ? HerdrTheme.accent : HerdrTheme.mist)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .herdrFont(.callout, weight: .medium)
                                        .lineLimit(1)
                                    Text("Revision \(profile.revision)")
                                        .herdrFont(.caption, monospaced: true)
                                        .foregroundStyle(HerdrTheme.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: HerdrTheme.minHitTarget, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(
                                store.selectedProfileID == profile.id ? HerdrTheme.elevated : .clear,
                                in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-profile-\(profile.id)")
                    }
                }
                .padding(.horizontal, 8)
            }

            if !store.pendingProposals.isEmpty {
                Label("\(store.pendingProposals.count) pending proposal\(store.pendingProposals.count == 1 ? "" : "s")", systemImage: "doc.text.magnifyingglass")
                    .herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.mauve)
                    .padding(12)
            }
        }
        .background(HerdrTheme.ink)
        .accessibilityIdentifier("agent-profiles-sidebar")
    }
}
