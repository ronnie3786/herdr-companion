import SwiftUI

/// A reusable, prominent pull request section. It leads the Overview and sits
/// above the Documents/Links control so a recognized PR stays immediately
/// visible; general links remain in the secondary Links collection.
struct FirstMatePullRequestsSection: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let surface: FirstMateLinkSurface
    @Environment(\.colorScheme) private var scheme

    private var pullRequests: [FirstMateLink] { snapshot.pullRequestLinks }

    var body: some View {
        let palette = FirstMatePalette(scheme: scheme)
        // A section label over `.prlink` cards; no outer card and no accent
        // ornament (issue #70).
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.iconTint)
                    .accessibilityHidden(true)
                HerdrMicroLabel(text: "Pull requests")
                if !pullRequests.isEmpty {
                    HerdrCountBadge(count: pullRequests.count, style: .quiet)
                        .accessibilityIdentifier("first-mate-pr-count-\(surface.accessibilitySuffix)")
                }
                Spacer()
                if surface == .overview {
                    Button("Manage links") { store.showLinksCollection() }
                        .buttonStyle(.plain)
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                        .foregroundStyle(palette.accent)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                        .accessibilityIdentifier("first-mate-pr-manage-links")
                }
            }
            if pullRequests.isEmpty {
                Text("No pull request links yet. Save one from Documents → Links.")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(palette.tertiaryText)
                    .accessibilityIdentifier("first-mate-pr-empty-\(surface.accessibilitySuffix)")
            } else {
                ForEach(pullRequests) { link in
                    FirstMateProminentLinkRow(store: store, link: link, surface: surface)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-pr-section-\(surface.accessibilitySuffix)")
    }
}

/// MonoCode's `.prlink`: a small card with a signal pull glyph, the title and
/// one line of "host · path".
private struct FirstMateProminentLinkRow: View {
    @Bindable var store: FirstMateStore
    let link: FirstMateLink
    let surface: FirstMateLinkSurface
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        let palette = FirstMatePalette(scheme: scheme)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.pull")
                .herdrFont(size: 13)
                .foregroundStyle(FirstMateStatusColors.color(for: .awaitingDirection, scheme: scheme))
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title.isEmpty ? link.url : link.title)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                    .accessibilityIdentifier("first-mate-pr-\(surface.accessibilitySuffix)-title-\(link.id)")
                Text(FirstMateLinkMeta.line(for: link))
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(link.url)
                if let provenance = link.provenanceSummary {
                    Text(provenance)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FirstMateLinkActionsView(link: link, actionPrefix: "first-mate-pr-\(surface.accessibilitySuffix)-", copied: $copied)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .herdrCard(radius: HerdrTheme.Radius.composer)
        .accessibilityIdentifier("first-mate-pr-\(surface.accessibilitySuffix)-\(link.id)")
    }
}

/// "host · path" for a link card.
enum FirstMateLinkMeta {
    static func line(for link: FirstMateLink) -> String {
        guard let url = URL(string: link.url), let host = url.host() else { return link.hostLabel ?? link.url }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? (link.hostLabel ?? host) : "\(link.hostLabel ?? host) · \(path)"
    }
}

/// The Links sub-tab inside the existing Documents inspector.
struct FirstMateLinksView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    @State private var drafts = FirstMateLinkDraftBox()
    @State private var showHidden = false

    /// The store lifecycle plus feature ID scopes every draft, so switching
    /// features or companions never surfaces another destination's input.
    private var destinationKey: String {
        FirstMateLinkDraftBox.key(lifecycleID: store.lifecycle.opaqueID, featureID: snapshot.feature.id)
    }

    private var draftState: FirstMateLinkDraftState { drafts.state(for: destinationKey) }

    private var urlText: Binding<String> {
        Binding(get: { draftState.draft.url }, set: { drafts.setURL($0, for: destinationKey) })
    }

    private var titleText: Binding<String> {
        Binding(get: { draftState.draft.title }, set: { drafts.setTitle($0, for: destinationKey) })
    }

    private var classification: Binding<FirstMateLinkClassification> {
        Binding(get: { draftState.classification },
                set: { drafts.setClassification($0, for: destinationKey) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            addForm
            linkGroup(title: "Pull requests", links: snapshot.pullRequestLinks, empty: "No pull request links yet.", prefix: "first-mate-link-pr-")
            linkGroup(title: "Other links", links: snapshot.otherLinks, empty: "No other links saved yet.", prefix: "first-mate-link-other-")
            if showHidden {
                linkGroup(title: "Hidden links", links: snapshot.hiddenLinks, empty: "No hidden links.", prefix: "first-mate-link-hidden-")
            }
            Toggle(isOn: $showHidden) {
                Text("Show hidden")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityIdentifier("first-mate-links-show-hidden")
        }
        .onChange(of: store.lifecycle) { drafts = FirstMateLinkDraftBox() }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HerdrMicroLabel(text: "Add a link")
            TextField("https://…", text: urlText)
                .textFieldStyle(.plain)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .padding(.horizontal, 8)
                .frame(height: HerdrTheme.ControlHeight.large)
                .herdrField()
                .accessibilityIdentifier("first-mate-link-add-url")
            TextField("Optional title", text: titleText)
                .textFieldStyle(.plain)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .padding(.horizontal, 8)
                .frame(height: HerdrTheme.ControlHeight.large)
                .herdrField()
                .accessibilityIdentifier("first-mate-link-add-title")
            Picker("Classification", selection: classification) {
                ForEach(FirstMateLinkClassification.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .herdrFont(size: HerdrTheme.TextSize.small)
            .frame(maxWidth: 240, alignment: .leading)
            .accessibilityIdentifier("first-mate-link-add-kind")
            HStack(spacing: 10) {
                Button("Add link") { save() }
                    .buttonStyle(HerdrButtonStyle(kind: .primary))
                    .disabled(store.isSavingLink || draftState.draft.isEmpty || !store.canManageLinks || !store.canMutateLinks)
                    .accessibilityIdentifier("first-mate-link-add-submit")
                if store.isSavingLink {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("first-mate-link-add-busy")
                }
            }
            if let failure = store.linkMutationError {
                Text(failure)
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-link-error")
            } else if !store.canManageLinks {
                Text(FirstMateStore.linksUpgradeMessage)
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-link-unsupported")
            }
        }
        .padding(12)
        .herdrCard()
    }

    @ViewBuilder
    private func linkGroup(title: String, links: [FirstMateLink], empty: String, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HerdrMicroLabel(text: title, count: links.isEmpty ? nil : links.count)
            if links.isEmpty {
                Text(empty).herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.tertiaryText)
            } else {
                ForEach(links) { link in
                    FirstMateLinkRow(store: store, link: link, actionPrefix: prefix)
                        .herdrHairline(.bottom, color: HerdrTheme.rowDivider)
                }
            }
        }
        .accessibilityIdentifier("\(prefix)group")
    }

    private func save() {
        let context = store.operationContext
        let key = destinationKey
        let pending = draftState.draft
        guard !pending.isEmpty else { return }
        Task {
            guard await store.saveLink(pending, expectedContext: context) else { return }
            // Clear only the submitted destination and only when the visible
            // draft still matches it, so an edit made while the request was
            // pending is never discarded.
            drafts.complete(key, submitted: pending)
        }
    }
}

private struct FirstMateLinkRow: View {
    @Bindable var store: FirstMateStore
    let link: FirstMateLink
    let actionPrefix: String
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: link.isPullRequest ? "arrow.triangle.pull" : "link")
                .herdrFont(size: 13)
                .foregroundStyle(HerdrTheme.iconTint)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title.isEmpty ? link.url : link.title)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .accessibilityIdentifier("\(actionPrefix)title-\(link.id)")
                if let host = link.hostLabel {
                    Text(host).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                }
                Text(link.url).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(2).textSelection(.enabled)
                HStack(spacing: 8) {
                    if let provenance = link.provenanceSummary {
                        Text(provenance).herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                    if link.hidden {
                        Label("Hidden", systemImage: "eye.slash")
                            .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Button("Open") { _ = FirstMateLinkActions.open(link) }
                        .disabled(link.destination == nil)
                        .help("Open \(link.url) in the default browser")
                        .accessibilityIdentifier("\(actionPrefix)open-\(link.id)")
                    Button(copied ? "Copied" : "Copy") { copied = FirstMateLinkActions.copy(link) }
                        .help("Copy \(link.url)")
                        .accessibilityIdentifier("\(actionPrefix)copy-\(link.id)")
                }
                Button(link.hidden ? "Restore" : "Hide", systemImage: link.hidden ? "eye" : "eye.slash") {
                    let context = store.operationContext
                    Task { _ = await store.setLinkHidden(link.id, hidden: !link.hidden, expectedContext: context) }
                }
                .disabled(!store.canManageLinks || !store.canMutateLinks || store.isSavingLink)
                .help(link.hidden ? "Restore \(link.title)" : "Hide \(link.title)")
                .accessibilityIdentifier("\(actionPrefix)\(link.hidden ? "restore" : "hide")-\(link.id)")
            }
            .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.small))
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("\(actionPrefix)row-\(link.id)")
    }
}

private struct FirstMateLinkActionsView: View {
    let link: FirstMateLink
    let actionPrefix: String
    @Binding var copied: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button("Open") { _ = FirstMateLinkActions.open(link) }
                .disabled(link.destination == nil)
                .help("Open \(link.url) in the default browser")
                .accessibilityIdentifier("\(actionPrefix)open-\(link.id)")
            Button(copied ? "Copied" : "Copy") { copied = FirstMateLinkActions.copy(link) }
                .help("Copy \(link.url)")
                .accessibilityIdentifier("\(actionPrefix)copy-\(link.id)")
        }
        .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.small))
    }
}
