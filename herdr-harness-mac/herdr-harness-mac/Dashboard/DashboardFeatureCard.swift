import SwiftUI

struct DashboardFeatureCard: View {
    let entry: DashboardFeatureEntry
    let open: () -> Void
    @State private var isHovered = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DashboardStatusView(status: entry.feature.status)
                    Spacer()
                    Text(entry.machineName).herdrFont(.caption2).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.feature.title).herdrFont(.body, weight: entry.needsAttention ? .semibold : .medium)
                        .lineLimit(1).foregroundStyle(HerdrTheme.text)
                    Text(entry.feature.workItemID ?? "Idea").herdrFont(.caption2).foregroundStyle(HerdrTheme.muted)
                }
                DashboardNowView(summary: entry.summary, needsAttention: entry.needsAttention)
                Text(entry.summary?.latestMessage ?? entry.feature.goal)
                    .herdrFont(.subheadline).foregroundStyle(HerdrTheme.mist).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if entry.needsAttention {
                        Text("→ \(entry.summary?.needsUserPrompt ?? "Open to give your direction")")
                            .foregroundStyle(HerdrTheme.working).lineLimit(1)
                    } else if let count = entry.summary?.runningAssignmentCount, count > 0 {
                        Text("\(count) agent\(count == 1 ? "" : "s") working").foregroundStyle(HerdrTheme.mist)
                    } else {
                        Text("Open conversation").foregroundStyle(HerdrTheme.muted)
                    }
                    Spacer(minLength: 0)
                    if let updated = entry.hostError == nil ? HerdrTimestamp.date(from: entry.feature.updatedAt) : entry.lastUpdated {
                        if entry.hostError != nil { Text("Last seen").foregroundStyle(HerdrTheme.muted) }
                        DashboardAgeText(date: updated).foregroundStyle(HerdrTheme.muted).lineLimit(1).fixedSize()
                    }
                }.herdrFont(.caption2)
            }
            .padding(16).frame(width: 360, height: 258, alignment: .topLeading)
            .background(isHovered ? HerdrTheme.input : HerdrTheme.elevated, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(isHovered ? HerdrTheme.accent.opacity(0.6) : HerdrTheme.separator, lineWidth: 1) }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { isHovered = $0 }
        .help("Open \(entry.feature.title) on \(entry.machineName)")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard-feature-\(entry.id)")
    }
}
