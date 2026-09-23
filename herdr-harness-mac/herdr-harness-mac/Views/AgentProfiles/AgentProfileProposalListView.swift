import SwiftUI

struct AgentProfileProposalListView: View {
    @Bindable var store: AgentProfilesStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if store.pendingProposals.isEmpty {
                    ContentUnavailableView(
                        "No pending proposals",
                        systemImage: "checkmark.circle",
                        description: Text("Agent suggestions appear here for review; they never change effective instructions automatically.")
                    )
                    .frame(minHeight: 120)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Decision reason")
                                .herdrFont(.subheadline, weight: .semibold)
                            Spacer()
                            Text("\(store.proposalDecisionReason.utf8.count) / \(AgentProfileLimits.maximumReasonBytes) bytes")
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(store.proposalDecisionReason.utf8.count <= AgentProfileLimits.maximumReasonBytes ? HerdrTheme.muted : HerdrTheme.alert)
                        }
                        TextField("Required reason", text: $store.proposalDecisionReason, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                    }

                    ForEach(store.pendingProposals) { proposal in
                        proposalCard(proposal)
                    }
                }
            }
            .padding(6)
        } label: {
            Label("Pending proposals", systemImage: "doc.text.magnifyingglass")
        }
        .frame(maxWidth: 900, alignment: .leading)
        .disabled(store.hasPendingMutation)
    }

    private func proposalCard(_ proposal: AgentProfileProposal) -> some View {
        let current = store.currentProfile(for: proposal)
        let hasConflict = current?.revision != proposal.baseRevision

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(current?.name ?? "Unknown profile")
                        .herdrFont(.headline, weight: .semibold)
                    Text("Proposed by \(proposal.actor) from revision \(proposal.baseRevision)")
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
                if hasConflict {
                    Label("Revision conflict", systemImage: "exclamationmark.triangle")
                        .herdrFont(.caption, weight: .medium)
                        .foregroundStyle(HerdrTheme.alert)
                }
            }

            if !proposal.reason.isEmpty {
                Text(proposal.reason)
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.mist)
            }

            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Current SOUL.md").herdrFont(.caption, weight: .semibold)
                    Text("Proposed SOUL.md").herdrFont(.caption, weight: .semibold)
                }
                GridRow {
                    diffDocument(current?.soul ?? "")
                    diffDocument(proposal.soul)
                }
                GridRow {
                    Text("Current USER.md").herdrFont(.caption, weight: .semibold)
                    Text("Proposed USER.md").herdrFont(.caption, weight: .semibold)
                }
                GridRow {
                    diffDocument(current?.user ?? "")
                    diffDocument(proposal.user)
                }
            }

            HStack {
                Spacer()
                Button("Reject", systemImage: "xmark", role: .destructive) {
                    Task { await store.reject(proposal) }
                }
                .buttonStyle(.bordered)
                .disabled(store.isSaving || store.hasPendingMutation || !store.proposalDecisionReasonIsValid)

                Button("Approve", systemImage: "checkmark") {
                    Task { await store.approve(proposal) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    store.isSaving
                        || store.hasPendingMutation
                        || !store.proposalDecisionReasonIsValid
                        || hasConflict
                        || current == nil
                )
            }
        }
        .padding(14)
        .background(HerdrTheme.ink.opacity(0.66), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hasConflict ? HerdrTheme.alert.opacity(0.55) : HerdrTheme.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-profile-proposal-\(proposal.id)")
    }

    private func diffDocument(_ text: String) -> some View {
        ScrollView {
            Text(text.isEmpty ? "Empty" : text)
                .font(.body.monospaced())
                .foregroundStyle(text.isEmpty ? HerdrTheme.muted : HerdrTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .frame(minHeight: 90, maxHeight: 180)
        .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: 7))
    }
}
