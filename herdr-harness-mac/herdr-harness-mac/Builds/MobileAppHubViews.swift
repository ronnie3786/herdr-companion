import SwiftUI

/// The app icon a build carries, or its first letter while it loads or when
/// the build has none.
struct MobileAppHubIcon: View {
    let url: URL?
    let name: String
    let size: CGFloat
    var tint = HerdrTheme.accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 10%, like the ticket: the letter keeps 4.5:1 on a hovered row.
                    .background(tint.opacity(0.10))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(HerdrTheme.outline, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

private struct MobileAppHubTicket: View {
    let ticket: String
    let tint: Color

    var body: some View {
        Text(ticket)
            .herdrFont(.caption, weight: .semibold, monospacedDigit: true)
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            // 10%: the ticket stays at 4.5:1 on a hovered row over the dusk glass.
            .background(tint.opacity(0.10), in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

private struct MobileAppHubRefreshKey: Equatable {
    let query: MobileAppHubFeed.Query?
    let active: Bool
}

extension View {
    /// Keeps `feed` current for `query` while the app is active. Attach it to a
    /// view that is always on screen: the sections themselves disappear while
    /// there is nothing to show.
    func mobileAppHubRefresh(_ feed: MobileAppHubFeed, query: MobileAppHubFeed.Query?, enabled: Bool = true) -> some View {
        modifier(MobileAppHubRefreshModifier(feed: feed, query: query, enabled: enabled))
    }
}

private struct MobileAppHubRefreshModifier: ViewModifier {
    let feed: MobileAppHubFeed
    let query: MobileAppHubFeed.Query?
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: MobileAppHubRefreshKey(query: query, active: enabled && scenePhase == .active)) {
            guard enabled, scenePhase == .active, let query else { return }
            await feed.poll(query)
        }
    }
}

// MARK: - First Mate Overview

/// Builds this First Mate's agents published: Mobile App Hub builds to install
/// on a phone, and simulator checkpoints to open in a simulator on the
/// feature's machine. Agents tag both with their First Mate automatically.
/// The Overview owns `feed` (the hub) and keeps it and `simulator` current.
struct FirstMateBuildsSection: View {
    let featureID: String
    let assignments: [(id: String, title: String)]
    let feed: MobileAppHubFeed
    let query: MobileAppHubFeed.Query?
    var simulator: FirstMateSimulatorContext? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var showsAll = false

    static let collapsedCount = 4

    var body: some View {
        let entries = FirstMateBuildEntry.merge(hub: query == nil ? [] : feed.builds, simulator: simulator?.feed.builds ?? [])
        if !entries.isEmpty {
            card(entries)
        }
    }

    private func card(_ entries: [FirstMateBuildEntry]) -> some View {
        let palette = FirstMatePalette(scheme: scheme)
        let shown = showsAll ? entries : Array(entries.prefix(Self.collapsedCount))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "iphone")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text("BUILDS")
                    .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
                    .tracking(0.6)
                    .foregroundStyle(palette.tertiaryText)
                    .accessibilityLabel("Builds")
                    .accessibilityAddTraits(.isHeader)
                Text("\(entries.count)")
                    .herdrFont(size: 9, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(palette.selectedFill, in: .capsule)
                    .accessibilityIdentifier("first-mate-builds-count")
                Spacer()
                if let error = feed.error ?? simulator?.feed.error {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(palette.iconTint)
                        .help(error)
                        .accessibilityLabel("Couldn't refresh builds")
                }
                if let query, !feed.builds.isEmpty {
                    Button("Open Mobile App Hub") { openURL(MobileAppHubPresentation.seeAllURL(feed.builds, hubURL: query.hubURL)) }
                        .buttonStyle(.herdrPlain)
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                        .foregroundStyle(palette.accent)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                }
            }
            if let status = simulator?.feed.status, status.configured, !status.canWatch, let reason = status.reason {
                Text(reason)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-simulator-status-note")
            }
            ForEach(shown) { entry in
                switch entry {
                case .hub(let build, let copy):
                    FirstMateBuildRow(
                        build: build,
                        madeBy: MobileAppHubPresentation.assignmentTitles(for: build, featureID: featureID, assignments: assignments),
                        palette: palette,
                        simulator: copy.flatMap { copy in simulator.map { (build: copy, context: $0) } }
                    ) { openURL(build.urls.page) }
                case .simulator(let build):
                    if let simulator {
                        FirstMateSimulatorBuildRow(
                            build: build, context: simulator,
                            madeBy: assignments.first { $0.id == build.assignmentID }?.title,
                            palette: palette)
                    }
                }
            }
            if entries.count > Self.collapsedCount {
                Button(showsAll ? "Show fewer" : "Show \(entries.count - Self.collapsedCount) more") { showsAll.toggle() }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(.rect)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardFill, in: .rect(cornerRadius: HerdrTheme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.Radius.card).strokeBorder(palette.line)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-builds-section")
    }
}

private struct FirstMateBuildRow: View {
    let build: MobileAppHubBuild
    let madeBy: [String]
    let palette: FirstMatePalette
    /// The simulator copy an agent saved with this build, when there is one.
    var simulator: (build: FirstMateSimulatorBuild, context: FirstMateSimulatorContext)? = nil
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    private var detail: String {
        var parts = ["\(build.app.name) \(build.versionLabel)"]
        if let machine = build.source.machine { parts.append(machine) }
        if !madeBy.isEmpty { parts.append("by \(madeBy.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hubButton
            if let simulator {
                FirstMateSimulatorOpenButton(build: simulator.build, context: simulator.context)
                    .padding(.leading, 46)
                    .padding(.bottom, 4)
            }
        }
    }

    private var hubButton: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                MobileAppHubIcon(url: build.urls.icon, name: build.app.name, size: 30, tint: palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let ticket = build.label.ticket { MobileAppHubTicket(ticket: ticket, tint: palette.accent) }
                        Text(build.title)
                            .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                    }
                    Text(detail)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(2)
                    if build.isSigningExpired() {
                        // The light scheme needs the darker blocked red (6.7:1).
                        Text("Signing expired: this build no longer installs")
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(FirstMateStatusColors.color(for: .blocked, scheme: scheme))
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if MobileAppHubPresentation.isFresh(build) {
                        Circle().fill(HerdrTheme.success).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    HerdrAgeText(date: build.date)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .monospacedDigit()
                        .foregroundStyle(palette.tertiaryText)
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .background(isHovered ? palette.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovered = $0 }
        .help("Open \(build.app.name) \(build.versionLabel) in Mobile App Hub")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-mate-build-\(build.id)")
    }
}
