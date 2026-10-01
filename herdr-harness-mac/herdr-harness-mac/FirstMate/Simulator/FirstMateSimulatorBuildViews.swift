import SwiftUI

/// "Open in Simulator" for one saved build. It opens (or focuses) the build's
/// simulator window; the window asks the companion to reuse a running
/// simulator or start one.
struct FirstMateSimulatorOpenButton: View {
    let build: FirstMateSimulatorBuild
    let context: FirstMateSimulatorContext
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = build.activePreview != nil
        Button {
            openWindow(id: HerdrWindowID.firstMateSimulator, value: context.target(for: build))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "iphone.gen3")
                    .accessibilityHidden(true)
                Text(running ? "Show Simulator" : "Open in Simulator")
                if running {
                    Circle().fill(HerdrTheme.success).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.small))
        .disabled(!build.launchable)
        .help(build.launchable
              ? (running ? "Show the running simulator for \(build.checkpointLabel)" : "Open \(build.checkpointLabel) in a simulator on this feature's machine")
              : (build.unavailableReason ?? "This build can't be opened"))
        .accessibilityLabel(running ? "Show simulator for \(build.checkpointLabel)" : "Open \(build.checkpointLabel) in Simulator")
        .accessibilityIdentifier("first-mate-simulator-open-\(build.id)")
    }
}

/// A saved simulator build with no Mobile App Hub counterpart, in the Builds section.
struct FirstMateSimulatorBuildRow: View {
    let build: FirstMateSimulatorBuild
    let context: FirstMateSimulatorContext
    let madeBy: String?
    let palette: FirstMatePalette

    private var detail: String {
        var parts: [String] = []
        if let app = build.appLabel { parts.append(app) }
        if let stage = build.stageTitle { parts.append(stage) }
        if let madeBy { parts.append("by \(madeBy)") }
        if build.origin == "external" { parts.append("saved outside First Mate") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 30 * 0.225, style: .continuous)
                    .fill(palette.accent.opacity(0.10))
                Image(systemName: "iphone.gen3")
                    .herdrFont(size: 14)
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 30, height: 30)
            .overlay { RoundedRectangle(cornerRadius: 30 * 0.225, style: .continuous).strokeBorder(HerdrTheme.outline, lineWidth: 0.5) }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(build.checkpointLabel)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(2)
                }
                if let reason = build.unavailableReason {
                    Text(reason)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(build.status == "registering" ? palette.secondaryText : HerdrTheme.warning)
                        .lineLimit(2)
                } else {
                    FirstMateSimulatorOpenButton(build: build, context: context)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if let date = build.date {
                DashboardAgeText(date: date)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-simulator-build-\(build.id)")
    }
}

/// A workflow stage's saved simulator builds, as a chip beside its agents and
/// documents: it opens the build directly, or lists them when there are several.
struct FirstMateSimulatorVisitChip: View {
    let visitID: String
    @Environment(\.firstMateSimulator) private var context
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let context {
            let builds = context.feed.builds(forVisit: visitID).filter(\.launchable)
            if let first = builds.first {
                if builds.count == 1 {
                    Button { open(first, context) } label: {
                        chip("Simulator", running: first.activePreview != nil)
                    }
                    .help("Open \(first.checkpointLabel) in Simulator")
                    .accessibilityLabel("Open \(first.checkpointLabel) in Simulator")
                    .accessibilityIdentifier("first-mate-simulator-visit-\(visitID)")
                } else {
                    Menu {
                        ForEach(builds) { build in
                            Button(menuTitle(build)) { open(build, context) }
                        }
                    } label: {
                        chip("\(builds.count) simulator builds", running: builds.contains { $0.activePreview != nil })
                    }
                    .help("Open one of this stage's simulator builds")
                    .accessibilityLabel("Open one of \(builds.count) simulator builds from this stage")
                    .accessibilityIdentifier("first-mate-simulator-visit-\(visitID)")
                }
            }
        }
    }

    /// The agents and documents chips' shape, with an accent glyph because it opens something.
    private func chip(_ title: String, running: Bool) -> some View {
        let palette = FirstMatePalette(scheme: scheme)
        return HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .herdrFont(size: 12)
                .foregroundStyle(palette.accent)
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(palette.secondaryText)
            if running {
                Circle().fill(HerdrTheme.success).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 22)
        .background(palette.chipFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(.rect)
    }

    private func menuTitle(_ build: FirstMateSimulatorBuild) -> String {
        var title = build.checkpointLabel
        if let date = build.date { title += " · " + HerdrTimestamp.compactAge(since: date) }
        if build.activePreview != nil { title += " · running" }
        return title
    }

    private func open(_ build: FirstMateSimulatorBuild, _ context: FirstMateSimulatorContext) {
        openWindow(id: HerdrWindowID.firstMateSimulator, value: context.target(for: build))
    }
}
