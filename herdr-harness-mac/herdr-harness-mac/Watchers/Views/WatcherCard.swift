import SwiftUI

struct WatcherCard: View {
    var entry: WatcherEntry
    var busy = false
    var preview = false
    var edit: () -> Void = {}
    var action: (String) -> Void = { _ in }
    var history: () -> Void = {}
    var build: () -> Void = {}
    private var w: Watcher { entry.watcher }
    private var tone: Color { WatcherAvatar.tone(w.avatar) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(w.live != nil ? .mint : tone).frame(width: 5, height: 5)
                Text(w.status).font(.system(size: 10)).foregroundStyle(HerdrTheme.secondaryText)
                Spacer()
                if !preview { Menu { Button("Edit setup", action: edit); Button("Edit with an agent", action: build) } label: { Image(systemName: "pencil") }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(HerdrTheme.secondaryText).help("Edit \(w.name)") }
            }
            WatcherAvatar(avatar: w.avatar, resting: w.resting, working: w.live != nil, attention: w.attention != nil).padding(.top, 13)
            Text(w.name).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center).padding(.top, 12)
            Text(who).font(.system(size: 10.5)).foregroundStyle(HerdrTheme.secondaryText).padding(.top, 7)
            WatcherSummaryView(markup: w.summary, schedule: w.scheduleSummary, tokens: w.fields["summary_tokens"]?.arrayValue).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 24)
            Spacer(minLength: 22)
            if let live = w.live {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(live.text("step_title", fallback: "Working")); Spacer(); Text("Step \(min(Int(live.number("step_index")) + 1, Int(live.number("step_count")))) of \(Int(live.number("step_count")))") }.font(.system(size: 10))
                    ProgressView(value: min(live.number("step_index"), live.number("step_count")), total: max(1, live.number("step_count"))).tint(.mint)
                }.foregroundStyle(.mint).padding(.bottom, 10)
            } else if let date = w.nextFire {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 4) { Image(systemName: "clock"); Text("Next:"); Text(WatchersDate.relative(date, now: context.date)).foregroundStyle(tone); Spacer() }.font(.system(size: 10.5)).foregroundStyle(HerdrTheme.secondaryText)
                }.padding(.bottom, 10)
            }
            if let attention = w.attention {
                Label("My last run needs attention.", systemImage: "exclamationmark.circle").font(.system(size: 10.5)).foregroundStyle(.pink).frame(maxWidth: .infinity, alignment: .leading).help(attention).padding(.bottom, 10)
            }
            if !preview {
                Divider().overlay(HerdrTheme.rowDivider)
                HStack(spacing: 14) {
                    if w.state == "draft" { Button("Create watcher", systemImage: "checkmark") { action("activate") } }
                    else {
                        Button(w.live == nil ? "Run now" : "Stop run", systemImage: w.live == nil ? "play" : "stop") { action(w.live == nil ? "run_now" : "stop") }
                        if w.state != "done" { Button(w.state == "paused" ? "Wake up" : "Pause", systemImage: w.state == "paused" ? "sunrise" : "pause") { action(w.state == "paused" ? "resume" : "pause") } }
                    }
                    Spacer(minLength: 0)
                    Button { history() } label: { Label("Past runs \(w.runsCount)", systemImage: "clock.arrow.circlepath") }
                }.font(.system(size: 10.5)).foregroundStyle(HerdrTheme.secondaryText).buttonStyle(.herdrPlain).padding(.top, 15).disabled(busy)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: .infinity, minHeight: preview ? 340 : 380, alignment: .top)
        .background { RoundedRectangle(cornerRadius: 15).fill(HerdrTheme.cardFill).overlay(alignment: .top) { LinearGradient(colors: [tone.opacity(0.045), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150).clipShape(.rect(cornerRadius: 15)) } }
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(w.live != nil ? Color.mint.opacity(0.55) : HerdrTheme.rowDivider, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
    private var who: String {
        let agent = w.steps.first { $0.kind == "agent" }
        let name = agent?.fields.text("display_name", fallback: agent?.fields.text("model", fallback: "Agent") ?? "Agent") ?? "Agent"
        return (w.kind == "script" ? "Script" : w.kind == "hybrid" ? "\(name) with scripts" : name) + " on " + entry.machineName
    }
}
