import SwiftUI

struct FirstMateAgentRow: View {
    @Bindable var store: FirstMateStore
    let agent: FirstMateAssignment
    @Environment(\.colorScheme) private var scheme

    private var sessions: [FirstMateSession] { store.snapshot?.sessions(for: agent.id) ?? [] }
    private var canOpen: Bool { agent.nativeSessionID != nil || !sessions.isEmpty }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(agent.title).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(agent.role.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let subtree = agent.subtreeUsage, subtree != agent.usage {
                        Text("Own · \(FirstMateUsageFormatting.inlineSummary(agent.usage))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("With descendants · \(FirstMateUsageFormatting.inlineSummary(subtree))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(FirstMateUsageFormatting.inlineSummary(agent.usage))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    FirstMateStatusLabel(status: agent.status)
                    if sessions.count > 1 {
                        Label("\(sessions.count) saved sessions", systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let verdict = agent.verdict, !verdict.isEmpty, verdict != "passed" {
                        Text("Verdict: \(verdict.replacingOccurrences(of: "_", with: " "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(FirstMatePalette(scheme: scheme).background, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(FirstMatePalette(scheme: scheme).line, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityHint(canOpen ? "Opens this agent's exact saved session and handoff history" : "This agent has not registered a saved session yet")
        .accessibilityIdentifier("first-mate-agent-\(agent.id)")
    }

    private func open() {
        Task {
            if agent.nativeSessionID != nil { await store.open(.session(agent)) }
            else if let session = sessions.last { await store.open(.history(session)) }
        }
    }
}
