import SwiftUI

/// The approved V1 card: status and edit, avatar, name, who, the summary
/// with chips, next run or the live step, attention, and actions.
struct WatcherCard: View {
    var entry: WatcherEntry
    var busy = false
    var preview = false
    var metrics: WatchersMetrics = .regular
    var edit: () -> Void = {}
    var action: (String) -> Void = { _ in }
    var history: () -> Void = {}
    var build: () -> Void = {}
    @State private var hovering = false
    private var w: Watcher { entry.watcher }
    private var tone: Color { WatcherAvatar.tone(w.avatar) }
    private var live: [String: PiJSONValue]? { w.live }
    var body: some View {
        VStack(spacing: 0) {
            top
            WatcherAvatar(avatar: w.avatar, resting: w.resting, working: live != nil, attention: w.attention != nil && live == nil, size: metrics.avatar)
                .padding(.bottom, 13)
            Text(w.name).font(WatchersStyle.font(metrics.name, weight: WatchersStyle.w550)).tracking(-0.4).foregroundStyle(HerdrTheme.primaryText)
                .multilineTextAlignment(.center).watchersLineHeight(metrics.name, 1.4).frame(maxWidth: .infinity).padding(.bottom, 5)
            who.font(.system(size: metrics.who)).multilineTextAlignment(.center).watchersLineHeight(metrics.who, 1.6).frame(maxWidth: .infinity).padding(.bottom, 18)
            WatcherSummaryView(markup: w.summary, schedule: w.scheduleSummary, tokens: w.fields["summary_tokens"]?.arrayValue, size: metrics.story, lineHeight: metrics.storyLine)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 18)
            Spacer(minLength: 0)
            if !preview {
                if let live { liveRow(live) } else { nextRow }
                if let attention = w.attention, live == nil {
                    Button(action: history) {
                        HStack(spacing: 6) { Image(systemName: "exclamationmark.circle").font(.system(size: metrics.small + 0.5)); Text("My last run needs attention.") }
                            .font(.system(size: metrics.small)).foregroundStyle(WatchersStyle.rose).watchersLineHeight(metrics.small, 1.5)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.herdrPlain).help(attention).padding(.bottom, 12)
                }
                actions
            }
        }
        .padding(.horizontal, metrics.cardSide).padding(.top, metrics.cardTop).padding(.bottom, preview ? 6 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            let wash = live != nil ? WatchersStyle.mint.opacity(0.063) : tone.opacity(0.06)
            RoundedRectangle(cornerRadius: 15).fill(HerdrTheme.cardFill)
                .overlay(alignment: .top) { LinearGradient(colors: [wash, .clear], startPoint: .top, endPoint: .bottom).frame(height: live != nil ? 220 : 150) }
                .clipShape(.rect(cornerRadius: 15))
        }
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(live != nil ? WatchersStyle.mint.opacity(0.45) : hovering ? tone.opacity(0.28) : HerdrTheme.outline, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .accessibilityElement(children: .contain)
    }
    /// Status on the left, edit on the right; the row reaches 8pt into the card's side padding.
    private var top: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(live != nil ? WatchersStyle.mint : w.resting ? HerdrTheme.secondaryText : tone.opacity(0.8)).frame(width: 5, height: 5)
                Text(w.status).font(.system(size: 9)).foregroundStyle(live != nil ? WatchersStyle.mint : HerdrTheme.secondaryText)
            }
            Spacer(minLength: 0)
            if !preview {
                Menu { Button("Edit with an agent", action: build); Button("Edit setup", action: edit) } label: { Label { Text("Edit \(w.name)") } icon: { WatcherEditGlyph() } }
                    .herdrIconMenu(visualSize: 25, tint: HerdrTheme.secondaryText)
                    .disabled(live != nil)
                    .help("Edit \(w.name)")
            }
        }
        .frame(minHeight: 27).padding(.horizontal, -8)
    }
    private var who: Text {
        let agent = w.steps.first { $0.kind == "agent" }
        let name = agent?.fields.text("display_name", fallback: agent?.fields.text("model", fallback: "Agent") ?? "Agent") ?? "Agent"
        let lead = Text(w.kind == "script" ? "Script" : name).foregroundStyle(HerdrTheme.proseText)
        let kind = w.kind == "hybrid" ? Text(" with scripts").foregroundStyle(HerdrTheme.secondaryText) : Text("")
        return lead + kind + Text(" on " + entry.machineName).foregroundStyle(HerdrTheme.secondaryText)
    }
    private var nextRow: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
                Image(systemName: w.state == "paused" ? "pause" : w.state == "done" ? "checkmark" : "clock").font(.system(size: metrics.small + 0.5)).foregroundStyle(HerdrTheme.secondaryText)
                if w.state == "paused" { Text("I’m resting until you wake me.") }
                else if w.state == "done" { Text("My one-time task is complete.") }
                else if w.state == "draft" { Text("Not scheduled until you create it.") }
                else if let date = w.nextFire { Text("Next: ") + Text(WatchersDate.relative(date, now: context.date)).foregroundStyle(tone).monospacedDigit() }
                else { Text("No upcoming run scheduled.") }
            }
            .font(.system(size: metrics.small)).foregroundStyle(HerdrTheme.proseText).watchersLineHeight(metrics.small, 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 11).padding(.bottom, 14)
    }
    private func liveRow(_ live: [String: PiJSONValue]) -> some View {
        let count = max(1, live.number("step_count")), index = min(live.number("step_index"), count - 1)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) { Text(stage(live)).lineLimit(1); Spacer(minLength: 0); Text("Step \(Int(index) + 1) of \(Int(count))").monospacedDigit() }
            Capsule().fill(WatchersStyle.mint.opacity(0.094)).frame(height: 3)
                .overlay(alignment: .leading) { GeometryReader { g in Rectangle().fill(WatchersStyle.mint).frame(width: g.size.width * index / count) } }
                .clipShape(Capsule())
        }
        .font(.system(size: metrics.small)).foregroundStyle(WatchersStyle.mint).padding(.bottom, 12)
    }
    /// "Sol is running docs-check", "Checking for something new", or the step's title.
    private func stage(_ live: [String: PiJSONValue]) -> String {
        let id = live.text("step_id")
        let step = w.steps.first { $0.id == id } ?? (w.steps.indices.contains(Int(live.number("step_index"))) ? w.steps[Int(live.number("step_index"))] : nil)
        switch step?.kind {
        case "agent":
            let fields = step?.fields ?? [:]
            return "\(fields.text("display_name", fallback: "The agent")) is running \(fields.text("skill", fallback: "the instructions"))"
        case "gate": return "Checking for something new"
        default: return live.text("step_title", fallback: step?.title ?? "Working")
        }
    }
    private var actions: some View {
        VStack(spacing: 0) {
            Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1)
            HStack(spacing: 0) {
                if w.state == "draft" {
                    Button { action("activate") } label: { actionLabel("Create watcher", "checkmark") }.buttonStyle(WatcherActionButtonStyle(emphasized: true))
                } else {
                    Button { action(live == nil ? "run_now" : "stop") } label: { actionLabel(live == nil ? "Run now" : "Stop run", live == nil ? "play" : "stop") }
                        .buttonStyle(WatcherActionButtonStyle(emphasized: true))
                    Button { action(w.state == "paused" ? "resume" : "pause") } label: { actionLabel(w.state == "paused" ? "Wake up" : "Pause", w.state == "paused" ? "sunrise" : "pause") }
                        .buttonStyle(WatcherActionButtonStyle()).disabled(live != nil || w.state == "done")
                        .padding(.leading, metrics.actionGap + metrics.pauseLead)
                }
                Spacer(minLength: metrics.actionGap)
                Button(action: history) { actionLabel(w.runsCount > 0 ? "Past runs \(w.runsCount)" : "Past runs", "clock.arrow.circlepath") }
                    .buttonStyle(WatcherActionButtonStyle())
            }
            .padding(.vertical, metrics.actionPadding).disabled(busy)
        }
    }
    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: metrics.small + 0.5)); Text(title).lineLimit(1) }
            .font(.system(size: metrics.small)).padding(.vertical, 5).fixedSize()
    }
}
