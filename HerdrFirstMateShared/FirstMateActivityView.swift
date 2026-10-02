import SwiftUI

/// Shared activity semantics for the Mac and iOS Overview and Workflow panels.
struct FirstMateActivityView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot

    var body: some View {
        let activity = FirstMateActivity(snapshot: snapshot)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Active now").firstMateActivityFont(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("All agents (\(snapshot.assignments.count))") { store.inspector = .agents }
                    .buttonStyle(.plain).firstMateActivityFont(.caption)
                    .frame(minHeight: 44)
            }
            ForEach(activity.processingMessages) { message in
                FirstMateActivityMessageView(message: message, isProcessing: true)
            }
            ForEach(activity.activeAssignments) { agent in
                FirstMateAgentRow(store: store, agent: agent, style: .compact)
            }
            if !activity.hasActiveWork {
                Text(snapshot.feature.coordinatorOwner == nil ? "No active agent work reported." : "The coordinator is working. Current direction is unavailable from this companion.")
                    .firstMateActivityFont(.subheadline).foregroundStyle(.secondary)
            }

            Text("Queued next").firstMateActivityFont(.headline).accessibilityAddTraits(.isHeader)
            ForEach(activity.queuedMessages) { message in
                FirstMateActivityMessageView(message: message, isProcessing: false)
            }
            ForEach(activity.queuedAssignments) { agent in
                FirstMateAgentRow(store: store, agent: agent, style: .compact)
            }
            if snapshot.pendingMessagesTruncated == true {
                Text("More directions and background updates are queued. They will appear as earlier work finishes.")
                    .firstMateActivityFont(.caption).foregroundStyle(.secondary)
            } else if !activity.hasQueuedWork {
                Text(snapshot.pendingMessages == nil && snapshot.hasQueuedWork == true ? "The companion reports pending work. Queue details are unavailable." : "No queued directions or agents reported.")
                    .firstMateActivityFont(.subheadline).foregroundStyle(.secondary)
            }
            if !activity.followupStages.isEmpty {
                Text("Authorized next stages").firstMateActivityFont(.subheadline, weight: .semibold).accessibilityAddTraits(.isHeader)
                ForEach(Array(activity.followupStages.enumerated()), id: \.offset) { index, stage in
                    Text("\(index + 1). \(stage.replacingOccurrences(of: "_", with: " ").capitalized)")
                        .firstMateActivityFont(.subheadline)
                }
                Text("Recorded for this workflow step. New direction may change these stages.")
                    .firstMateActivityFont(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("first-mate-current-activity")
    }
}

// The app's Mac text-size preference and iOS Dynamic Type both remain effective.
extension View {
    func firstMateActivityFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        #if os(macOS)
        let size: CGFloat = switch style {
        case .headline: 15
        case .subheadline: 13
        default: 11
        }
        return herdrFont(size: size, weight: weight ?? (style == .headline ? .semibold : nil))
        #else
        return font(weight.map { Font.system(style).weight($0) } ?? Font.system(style))
        #endif
    }
}
