import SwiftUI

struct FirstMateAgentRow: View {
    @Bindable var store: FirstMateStore
    let agent: FirstMateAssignment
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button {
            Task {
                if agent.nativeSessionID != nil { await store.open(.session(agent)) }
                else if let retained = store.snapshot?.sessions(for: agent.id).last { await store.open(.history(retained)) }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle").herdrFont(.title2).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.title).herdrFont(.subheadline, weight: .medium)
                    Text("\(agent.role) · attempt \(agent.attempt) · revision \(agent.inputRevision)")
                        .herdrFont(.caption2).foregroundStyle(.secondary)
                    if let selection = agent.modelSelection {
                        Label(selection.compactDisplayName, systemImage: "cpu")
                            .herdrFont(.caption2).foregroundStyle(.secondary)
                            .help(selection.fullDisplayName)
                            .accessibilityLabel(selection.fullDisplayName)
                    }
                    if let subtree = agent.subtreeUsage, subtree != agent.usage {
                        Text("Own · \(FirstMateUsageFormatting.inlineSummary(agent.usage))")
                            .herdrFont(.caption).foregroundStyle(.secondary)
                        Text("With descendants · \(FirstMateUsageFormatting.inlineSummary(subtree))")
                            .herdrFont(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(FirstMateUsageFormatting.inlineSummary(agent.usage))
                            .herdrFont(.caption).foregroundStyle(.secondary)
                    }
                    if let count = store.snapshot?.sessions(for: agent.id).count, count > 1 {
                        Text("\(count) saved sessions").herdrFont(.caption).foregroundStyle(.secondary)
                    }
                    if let verdict = agent.verdict, !verdict.isEmpty {
                        Text("Verdict: \(verdict.replacingOccurrences(of: "_", with: " "))").herdrFont(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                FirstMateStatusLabel(status: agent.status)
            }.padding(12)
                .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain).disabled(agent.nativeSessionID == nil && store.snapshot?.sessions(for: agent.id).isEmpty != false)
        .help(agent.nativeSessionID.map { "Open saved session \($0)" } ?? "The agent has not registered a saved session yet")
        .accessibilityIdentifier("first-mate-agent-\(agent.id)")
    }
}
