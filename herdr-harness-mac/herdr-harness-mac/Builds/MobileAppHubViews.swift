import SwiftUI

/// The app icon a build carries, or its first letter while it loads or when
/// the build has none.
struct MobileAppHubIcon: View {
    let url: URL?
    let name: String
    let size: CGFloat
    var tint = HerdrTheme.primaryAction

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
                    .background(tint.opacity(0.16))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.stroke(.primary.opacity(0.08), lineWidth: 0.5) }
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
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 4))
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

// MARK: - Dashboard

/// The newest builds of the apps chosen in Settings → General → Builds.
/// Hidden until a hub and at least one app are configured, and while the hub
/// has no builds for them. `DashboardView` keeps `dashboard.builds` current.
struct DashboardBuildsSection: View {
    let dashboard: DashboardState
    let query: MobileAppHubFeed.Query?
    @Environment(\.openURL) private var openURL

    private var feed: MobileAppHubFeed { dashboard.builds }

    var body: some View {
        if let query, !feed.hasLoaded || !feed.builds.isEmpty {
            content(query)
        }
    }

    private func content(_ query: MobileAppHubFeed.Query) -> some View {
        let rows = MobileAppHubPresentation.dashboardRows(
            feed.builds, query: dashboard.search, focusMode: dashboard.focusMode)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DashboardSectionHeading(
                    title: MobileAppHubPresentation.dashboardTitle(feed.builds), identifier: "dashboard-builds"
                ) {
                    openURL(MobileAppHubPresentation.seeAllURL(feed.builds, hubURL: query.hubURL))
                }
                Spacer(minLength: 8)
                if let error = feed.error {
                    Label("Couldn't refresh", systemImage: "exclamationmark.triangle")
                        .herdrFont(.subheadline).foregroundStyle(HerdrTheme.warning)
                        .help(error)
                }
            }
            if !feed.hasLoaded {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            } else if rows.isEmpty {
                Label(dashboard.focusMode ? "No builds from the last day." : "No builds match your search.",
                      systemImage: "iphone")
                    .herdrFont(.callout).foregroundStyle(HerdrTheme.muted)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { build in
                        DashboardBuildRow(build: build) { openURL(build.urls.page) }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
            }
        }
        .padding(.horizontal, HerdrTheme.pagePadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-builds-section")
    }
}

struct DashboardBuildRow: View {
    let build: MobileAppHubBuild
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                MobileAppHubIcon(url: build.urls.icon, name: build.app.name, size: 22)
                if let ticket = build.label.ticket {
                    MobileAppHubTicket(ticket: ticket, tint: HerdrTheme.primaryAction)
                }
                Text(build.title)
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if build.isSigningExpired() {
                    Text("Signing expired").herdrFont(.subheadline).foregroundStyle(HerdrTheme.alert)
                }
                Text([build.versionLabel, build.source.machine].compactMap { $0 }.joined(separator: " · "))
                    .herdrFont(.subheadline, monospacedDigit: true).foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
                Text("000d")
                    .hidden()
                    .overlay(alignment: .trailing) { DashboardAgeText(date: build.date) }
                    .herdrFont(.subheadline, monospacedDigit: true)
                    .foregroundStyle(MobileAppHubPresentation.isFresh(build) ? HerdrTheme.success : HerdrTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(isHovered ? HerdrTheme.elevated : .clear, in: .rect(cornerRadius: 6))
            .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(build.app.name) \(build.versionLabel) in Mobile App Hub")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard-build-\(build.id)")
    }
}

// MARK: - First Mate Overview

/// Builds this First Mate's agents published. Agents tag builds with their
/// First Mate automatically when they publish from a First Mate session.
/// The Overview owns `feed` and keeps it current.
struct FirstMateBuildsSection: View {
    let featureID: String
    let assignments: [(id: String, title: String)]
    let feed: MobileAppHubFeed
    let query: MobileAppHubFeed.Query?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var showsAll = false

    static let collapsedCount = 4

    var body: some View {
        if let query, !feed.builds.isEmpty {
            card(query)
        }
    }

    private func card(_ query: MobileAppHubFeed.Query) -> some View {
        let palette = FirstMatePalette(scheme: scheme)
        let builds = feed.builds
        let shown = showsAll ? builds : Array(builds.prefix(Self.collapsedCount))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "iphone").foregroundStyle(palette.accent)
                Text("Builds").herdrFont(.subheadline, weight: .semibold)
                Text("\(builds.count)")
                    .herdrFont(.caption2, weight: .semibold)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(palette.accent.opacity(0.16), in: .capsule)
                    .accessibilityIdentifier("first-mate-builds-count")
                Spacer()
                if feed.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help(feed.error ?? "")
                        .accessibilityLabel("Couldn't refresh builds")
                }
                Button("Open Mobile App Hub") { openURL(MobileAppHubPresentation.seeAllURL(builds, hubURL: query.hubURL)) }
                    .buttonStyle(.plain).herdrFont(.caption)
                    .foregroundStyle(palette.accent)
            }
            ForEach(shown) { build in
                FirstMateBuildRow(
                    build: build,
                    madeBy: MobileAppHubPresentation.assignmentTitles(for: build, featureID: featureID, assignments: assignments),
                    palette: palette
                ) { openURL(build.urls.page) }
            }
            if builds.count > Self.collapsedCount {
                Button(showsAll ? "Show fewer" : "Show \(builds.count - Self.collapsedCount) more") { showsAll.toggle() }
                    .buttonStyle(.plain).herdrFont(.caption)
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: .rect(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(palette.accent)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-builds-section")
    }
}

private struct FirstMateBuildRow: View {
    let build: MobileAppHubBuild
    let madeBy: [String]
    let palette: FirstMatePalette
    let open: () -> Void
    @State private var isHovered = false

    private var detail: String {
        var parts = ["\(build.app.name) \(build.versionLabel)"]
        if let machine = build.source.machine { parts.append(machine) }
        if !madeBy.isEmpty { parts.append("by \(madeBy.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                MobileAppHubIcon(url: build.urls.icon, name: build.app.name, size: 30, tint: palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let ticket = build.label.ticket { MobileAppHubTicket(ticket: ticket, tint: palette.accent) }
                        Text(build.title).herdrFont(.subheadline, weight: .semibold).lineLimit(2)
                    }
                    Text(detail).herdrFont(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if build.isSigningExpired() {
                        Text("Signing expired: this build no longer installs")
                            .herdrFont(.caption2).foregroundStyle(HerdrTheme.alert)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if MobileAppHubPresentation.isFresh(build) {
                        Circle().fill(HerdrTheme.success).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    DashboardAgeText(date: build.date)
                        .herdrFont(.caption, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .background(isHovered ? palette.text.opacity(0.05) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(build.app.name) \(build.versionLabel) in Mobile App Hub")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-mate-build-\(build.id)")
    }
}
