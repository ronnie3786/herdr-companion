import SwiftUI

/// Overview's Builds card, as on the Mac (`FirstMateBuildsSection`): the
/// Mobile App Hub builds this First Mate's agents published, each with
/// Install (onto this device) and, when an agent saved a simulator copy,
/// Open in Simulator; plus simulator checkpoints saved on their own. Newest
/// first, four at a time. Hidden while there is nothing to show, and hub
/// builds stay hidden until Settings → Builds has a Mobile App Hub address.
///
/// It refreshes itself while it is on screen. An empty view runs no tasks, so
/// the inspector also attaches `firstMateBuildsRefresh(snapshot:)` to a view
/// that is always visible, which finds a feature's first build.
struct FirstMateBuildsSection: View {
    let snapshot: FirstMateSnapshot
    @Environment(\.firstMateInspectorContext) private var context

    var body: some View {
        if let context {
            FirstMateBuildsCard(snapshot: snapshot, context: context, feed: context.buildsFeed(snapshot: snapshot))
        }
    }
}

/// A workflow stage's simulator builds, beside its agents and documents chips
/// (the Mac's `FirstMateSimulatorVisitChip`): "Simulator" opens the stage's
/// one launchable build, "N simulator builds" lists them. A dot shows one is
/// running. The simulator opens full screen.
struct FirstMateSimulatorVisitChip: View {
    let visitID: String
    @Environment(\.firstMateInspectorContext) private var context

    var body: some View {
        if let context {
            FirstMateSimulatorVisitChipContent(visitID: visitID, context: context, feed: context.buildsFeed())
        }
    }
}

extension View {
    /// Keeps this feature's Builds (Mobile App Hub builds and simulator
    /// checkpoints) current while the view is on screen and the app is
    /// active. Attach it to a view that is always visible, such as the
    /// Overview and Workflow roots: the Builds card and stage chips disappear
    /// while there is nothing to show. Watchers share one refresh schedule.
    func firstMateBuildsRefresh(snapshot: FirstMateSnapshot? = nil) -> some View {
        modifier(FirstMateBuildsRefreshModifier(snapshot: snapshot))
    }

    fileprivate func firstMateBuildsWatch(_ feed: FirstMateBuildsFeed, context: FirstMateInspectorContext,
                                          snapshot: FirstMateSnapshot? = nil) -> some View {
        modifier(FirstMateBuildsWatchModifier(feed: feed, context: context, snapshot: snapshot))
    }
}

private struct FirstMateBuildsRefreshModifier: ViewModifier {
    let snapshot: FirstMateSnapshot?
    @Environment(\.firstMateInspectorContext) private var context

    func body(content: Content) -> some View {
        if let context {
            content.firstMateBuildsWatch(context.buildsFeed(snapshot: snapshot), context: context, snapshot: snapshot)
        } else {
            content
        }
    }
}

private struct FirstMateBuildsWatchModifier: ViewModifier {
    let feed: FirstMateBuildsFeed
    let context: FirstMateInspectorContext
    let snapshot: FirstMateSnapshot?
    @AppStorage(MobileAppHubSettings.hubURLKey) private var hubURLText = ""
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Equatable {
        let target: FirstMateFeatureTarget
        let query: MobileAppHubFeed.Query?
        let active: Bool
    }

    func body(content: Content) -> some View {
        let query = context.hubQuery(hubURLText: hubURLText)
        content.task(id: Key(target: context.target, query: query, active: scenePhase == .active)) {
            context.presentDemoIfNeeded(feed, snapshot: snapshot)
            guard !feed.isDemo, scenePhase == .active else { return }
            await feed.watch(hubQuery: query)
        }
    }
}

// MARK: - Card

private struct FirstMateBuildsCard: View {
    let snapshot: FirstMateSnapshot
    let context: FirstMateInspectorContext
    let feed: FirstMateBuildsFeed
    @AppStorage(MobileAppHubSettings.hubURLKey) private var hubURLText = ""
    @State private var showsAll = false
    @State private var simulator: FirstMateSimulatorWindowTarget?
    @State private var message: FirstMateBuildsMessage?
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicType

    static let collapsedCount = 4

    /// Demo builds show without a hub address; nothing is fetched for them.
    private var hubURL: URL? {
        feed.isDemo ? FirstMateBuildsDemo.hubURL : context.hubQuery(hubURLText: hubURLText)?.hubURL
    }

    var body: some View {
        let entries = FirstMateBuildEntry.merge(hub: hubURL == nil ? [] : feed.hub.builds, simulator: feed.simulator.builds)
        if !entries.isEmpty {
            card(entries)
                .firstMateBuildsWatch(feed, context: context, snapshot: snapshot)
                .fullScreenCover(item: $simulator) { target in
                    FirstMateSimulatorCover(model: context.model, target: target, feed: feed)
                }
                .alert(item: $message) { message in
                    Alert(title: Text(message.title), message: Text(message.body))
                }
        }
    }

    private func card(_ entries: [FirstMateBuildEntry]) -> some View {
        let shown = showsAll ? entries : Array(entries.prefix(Self.collapsedCount))
        return VStack(alignment: .leading, spacing: 0) {
            header(count: entries.count)
            if let status = feed.simulator.status, status.configured, !status.canWatch, let reason = status.reason {
                Text(reason)
                    .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("first-mate-simulator-status-note")
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                row(entry)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1).accessibilityHidden(true)
                        }
                    }
            }
            if entries.count > Self.collapsedCount {
                Button(showsAll ? "Show fewer" : "Show \(entries.count - Self.collapsedCount) more") { showsAll.toggle() }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(.footnote, weight: .semibold).foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: HerdrTheme.minHitTarget).contentShape(.rect)
                    .accessibilityIdentifier("first-mate-builds-show-more")
            }
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .herdrCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-builds-section")
        .composerLayoutMeasurement(id: "first-mate-builds-section")
    }

    @ViewBuilder private func header(count: Int) -> some View {
        if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) { title(count: count); Spacer(minLength: 8); errorButton }
                    .frame(minHeight: HerdrTheme.minHitTarget)
                hubLink
            }
        } else {
            HStack(spacing: 6) {
                title(count: count)
                Spacer(minLength: 8)
                errorButton
                hubLink
            }
            .frame(minHeight: HerdrTheme.minHitTarget)
        }
    }

    private func title(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(HerdrTheme.accent)
                .accessibilityHidden(true)
            HerdrMicroLabel(text: "Builds", count: count)
                .accessibilityIdentifier("first-mate-builds-count")
        }
    }

    @ViewBuilder private var errorButton: some View {
        if let error = feed.hub.error ?? feed.simulator.error {
            Button {
                message = FirstMateBuildsMessage(title: "Couldn't refresh builds", body: error)
            } label: {
                Label("Couldn't refresh builds", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(HerdrIconButtonStyle(visualSize: 28, tint: HerdrTheme.warning))
            .accessibilityIdentifier("first-mate-builds-error")
        }
    }

    @ViewBuilder private var hubLink: some View {
        if let hubURL, !feed.hub.builds.isEmpty {
            Button("Mobile App Hub") {
                open(MobileAppHubPresentation.seeAllURL(feed.hub.builds, hubURL: hubURL))
            }
            .buttonStyle(.herdrPlain)
            .herdrFont(.footnote, weight: .semibold).foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: HerdrTheme.minHitTarget).contentShape(.rect)
            .accessibilityHint("Opens Mobile App Hub")
            .accessibilityIdentifier("first-mate-builds-hub-link")
        }
    }

    @ViewBuilder private func row(_ entry: FirstMateBuildEntry) -> some View {
        switch entry {
        case .hub(let build, let copy):
            FirstMateHubBuildRow(
                build: build,
                madeBy: MobileAppHubPresentation.assignmentTitles(
                    for: build, featureID: snapshot.feature.id,
                    assignments: snapshot.assignments.map { ($0.id, $0.title) }),
                simulatorCopy: copy,
                openPage: { open(build.urls.page) },
                install: { install(build) },
                openSimulator: openSimulator)
        case .simulator(let build):
            FirstMateSimulatorBuildRow(
                build: build,
                madeBy: snapshot.assignments.first { $0.id == build.assignmentID }?.title,
                openSimulator: openSimulator)
        }
    }

    private func openSimulator(_ build: FirstMateSimulatorBuild) {
        simulator = FirstMateSimulatorWindowTarget(machineID: context.target.machineID, featureID: build.featureID, buildID: build.id)
    }

    /// The `itms-services` link installs on this device; an older hub without
    /// one gets its build page, which has its own Install button.
    private func install(_ build: MobileAppHubBuild) {
        guard !feed.isDemo else {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            message = .demo("Install puts a build on this \(device) from Mobile App Hub. Demo builds are synthetic, so nothing installs.")
            return
        }
        openURL(build.urls.install ?? build.urls.page)
    }

    private func open(_ url: URL) {
        guard !feed.isDemo else {
            message = .demo("This opens Mobile App Hub. Demo builds are synthetic and have no hub page.")
            return
        }
        openURL(url)
    }
}

private struct FirstMateBuildsMessage: Identifiable {
    let title: String
    let body: String
    var id: String { title + body }

    static func demo(_ body: String) -> Self { Self(title: "Demo build", body: body) }
}

// MARK: - Rows

/// A Mobile App Hub build: tapping it opens its hub page; Install and the
/// simulator copy's button sit underneath.
private struct FirstMateHubBuildRow: View {
    let build: MobileAppHubBuild
    let madeBy: [String]
    let simulatorCopy: FirstMateSimulatorBuild?
    let openPage: () -> Void
    let install: () -> Void
    let openSimulator: (FirstMateSimulatorBuild) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var detail: String {
        var parts = ["\(build.app.name) \(build.versionLabel)"]
        if let machine = build.source.machine, !machine.isEmpty { parts.append(machine) }
        if !madeBy.isEmpty { parts.append("by \(madeBy.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let expired = build.isSigningExpired()
        let large = dynamicType.isAccessibilitySize
        let age = FirstMateBuildAge(date: build.date, fresh: MobileAppHubPresentation.isFresh(build))
        VStack(alignment: .leading, spacing: 8) {
            Button(action: openPage) {
                HStack(alignment: .top, spacing: 10) {
                    FirstMateBuildIcon(url: build.urls.icon, name: build.app.name)
                    VStack(alignment: .leading, spacing: 3) {
                        // Large text: the ticket and the age get lines of their own.
                        if large {
                            ticket
                            titleText
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 6) { ticket; titleText }
                        }
                        Text(detail)
                            .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                            .lineLimit(large ? 4 : 2)
                        if expired {
                            Text("Signing expired: this build no longer installs")
                                .herdrFont(.footnote).foregroundStyle(HerdrTheme.alert)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if large { age }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !large { age }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.herdrPlain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens this build in Mobile App Hub")
            .accessibilityIdentifier("first-mate-build-\(build.id)")

            FirstMateBuildActions {
                Button(action: install) {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .buttonStyle(FirstMateBuildActionStyle(accent: true))
                .disabled(expired)
                .accessibilityLabel("Install \(build.app.name) \(build.versionLabel) on this device")
                .accessibilityIdentifier("first-mate-build-install-\(build.id)")
                .composerLayoutMeasurement(id: "first-mate-build-install-\(build.id)")
                if let simulatorCopy {
                    FirstMateSimulatorOpenButton(build: simulatorCopy, open: openSimulator)
                }
            }
            .padding(.leading, large ? 0 : FirstMateBuildIcon.size + 10)
        }
    }

    @ViewBuilder private var ticket: some View {
        if let ticket = build.label.ticket, !ticket.isEmpty { FirstMateBuildTicket(ticket: ticket) }
    }

    private var titleText: some View {
        Text(build.title)
            .herdrFont(.subheadline, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
            .lineLimit(dynamicType.isAccessibilitySize ? 4 : 2)
    }
}

/// A saved simulator build with no Mobile App Hub counterpart.
private struct FirstMateSimulatorBuildRow: View {
    let build: FirstMateSimulatorBuild
    let madeBy: String?
    let openSimulator: (FirstMateSimulatorBuild) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var detail: String {
        var parts: [String] = []
        if let app = build.appLabel { parts.append(app) }
        if let stage = build.stageTitle { parts.append(stage) }
        if let madeBy { parts.append("by \(madeBy)") }
        if build.origin == "external" { parts.append("saved outside First Mate") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let large = dynamicType.isAccessibilitySize
        HStack(alignment: .top, spacing: 10) {
            FirstMateBuildPhoneTile()
            VStack(alignment: .leading, spacing: 3) {
                if large, let date = build.date { FirstMateBuildAge(date: date, fresh: false) }
                Text(build.checkpointLabel)
                    .herdrFont(.subheadline, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                        .lineLimit(2)
                }
                if let reason = build.unavailableReason {
                    Text(reason)
                        .herdrFont(.footnote)
                        .foregroundStyle(build.status == "registering" ? HerdrTheme.secondaryText : HerdrTheme.warning)
                        .lineLimit(3)
                } else {
                    FirstMateSimulatorOpenButton(build: build, open: openSimulator)
                        .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !large, let date = build.date {
                FirstMateBuildAge(date: date, fresh: false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-simulator-build-\(build.id)")
    }
}

/// "Open in Simulator", or "Show Simulator" with a dot while it runs.
struct FirstMateSimulatorOpenButton: View {
    let build: FirstMateSimulatorBuild
    let open: (FirstMateSimulatorBuild) -> Void

    var body: some View {
        let running = build.activePreview != nil
        Button { open(build) } label: {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3").accessibilityHidden(true)
                Text(running ? "Show Simulator" : "Open in Simulator")
                if running { FirstMateRunningDot() }
            }
        }
        .buttonStyle(FirstMateBuildActionStyle(accent: false))
        .disabled(!build.launchable)
        .accessibilityLabel(running ? "Show simulator for \(build.checkpointLabel)" : "Open \(build.checkpointLabel) in Simulator")
        .accessibilityHint(build.launchable ? "" : (build.unavailableReason ?? "This build can't be opened"))
        .accessibilityIdentifier("first-mate-simulator-open-\(build.id)")
        .composerLayoutMeasurement(id: "first-mate-simulator-open-\(build.id)")
    }
}

// MARK: - Stage chip

private struct FirstMateSimulatorVisitChipContent: View {
    let visitID: String
    let context: FirstMateInspectorContext
    let feed: FirstMateBuildsFeed
    @State private var simulator: FirstMateSimulatorWindowTarget?

    var body: some View {
        let builds = feed.simulator.builds(forVisit: visitID).filter(\.launchable)
        if let first = builds.first {
            Group {
                if builds.count == 1 {
                    Button { open(first) } label: {
                        chip("Simulator", running: first.activePreview != nil)
                    }
                    .accessibilityLabel("Open \(first.checkpointLabel) in Simulator")
                } else {
                    Menu {
                        ForEach(builds) { build in
                            Button(menuTitle(build), systemImage: "iphone.gen3") { open(build) }
                        }
                    } label: {
                        chip("\(builds.count) simulator builds", running: builds.contains { $0.activePreview != nil })
                    }
                    .accessibilityLabel("Open one of \(builds.count) simulator builds from this stage")
                }
            }
            .buttonStyle(.herdrPlain)
            .accessibilityIdentifier("first-mate-simulator-visit-\(visitID)")
            .composerLayoutMeasurement(id: "first-mate-simulator-visit-\(visitID)")
            .firstMateBuildsWatch(feed, context: context)
            .fullScreenCover(item: $simulator) { target in
                FirstMateSimulatorCover(model: context.model, target: target, feed: feed)
            }
        }
    }

    /// The agents and documents chips' shape, with an accent glyph because it opens something.
    private func chip(_ title: String, running: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3").font(.system(size: 12, weight: .medium)).foregroundStyle(HerdrTheme.accent)
            Text(title).herdrFont(.footnote).foregroundStyle(HerdrTheme.secondaryText)
            if running { FirstMateRunningDot() }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 28)
        .background(HerdrTheme.chipFill, in: .rect(cornerRadius: 8))
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(.rect)
    }

    private func menuTitle(_ build: FirstMateSimulatorBuild) -> String {
        var title = build.checkpointLabel
        if let date = build.date { title += " · " + HerdrTimestamp.compactAge(since: date) }
        if build.activePreview != nil { title += " · running" }
        return title
    }

    private func open(_ build: FirstMateSimulatorBuild) {
        simulator = FirstMateSimulatorWindowTarget(machineID: context.target.machineID, featureID: build.featureID, buildID: build.id)
    }
}

// MARK: - Pieces

/// The build's app icon, or its first letter while it loads or when the build has none.
struct FirstMateBuildIcon: View {
    static let size: CGFloat = 32
    let url: URL?
    let name: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.size * 0.225, style: .continuous)
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: Self.size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HerdrTheme.accent.opacity(0.10))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(HerdrTheme.outline, lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

private struct FirstMateBuildPhoneTile: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FirstMateBuildIcon.size * 0.225, style: .continuous)
        Image(systemName: "iphone.gen3")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(HerdrTheme.accent)
            .frame(width: FirstMateBuildIcon.size, height: FirstMateBuildIcon.size)
            .background(HerdrTheme.accent.opacity(0.10), in: shape)
            .overlay { shape.strokeBorder(HerdrTheme.outline, lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

private struct FirstMateBuildTicket: View {
    let ticket: String

    var body: some View {
        Text(ticket)
            .herdrFont(size: 12, weight: .semibold, monospaced: true, relativeTo: .caption)
            .foregroundStyle(HerdrTheme.accent)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(HerdrTheme.accent.opacity(0.12), in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

private struct FirstMateBuildAge: View {
    let date: Date
    let fresh: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 5) {
                if fresh { FirstMateRunningDot() }
                Text(HerdrTimestamp.compactAge(since: date, now: context.date))
                    .herdrFont(.footnote).monospacedDigit().foregroundStyle(HerdrTheme.tertiaryText)
            }
            .padding(.top, 2)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(HerdrTimestamp.spokenAge(since: date, now: context.date))
        }
    }
}

struct FirstMateRunningDot: View {
    var body: some View {
        Circle().fill(HerdrTheme.success).frame(width: 6, height: 6).accessibilityHidden(true)
    }
}

/// Install and Open in Simulator side by side, stacked when they don't fit.
private struct FirstMateBuildActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

/// The prototype's small outlined pill: 32 pt to see, 44 pt to tap.
struct FirstMateBuildActionStyle: ButtonStyle {
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        FirstMateBuildActionBody(configuration: configuration, accent: accent)
    }
}

private struct FirstMateBuildActionBody: View {
    let configuration: ButtonStyle.Configuration
    let accent: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .herdrFont(.footnote, weight: .semibold)
            .foregroundStyle(accent ? HerdrTheme.accent : HerdrTheme.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(configuration.isPressed ? HerdrTheme.selectedFill : HerdrTheme.inkFill(0.04),
                        in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(HerdrTheme.outline, lineWidth: 1) }
            .opacity(enabled ? 1 : 0.42)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
    }
}
