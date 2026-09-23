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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull")
                    .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                Text("Pull requests").herdrFont(.subheadline, weight: .semibold)
                if !pullRequests.isEmpty {
                    Text("\(pullRequests.count)")
                        .herdrFont(.caption2, weight: .semibold)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(FirstMatePalette(scheme: scheme).accent.opacity(0.16), in: .capsule)
                        .accessibilityIdentifier("first-mate-pr-count-\(surface.accessibilitySuffix)")
                }
                Spacer()
                if surface == .overview {
                    Button("Manage links") { store.inspector = .documents }
                        .buttonStyle(.plain).herdrFont(.caption)
                        .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                        .accessibilityIdentifier("first-mate-pr-manage-links")
                }
            }
            if pullRequests.isEmpty {
                Text("No pull request links yet. Save one from Documents → Links.")
                    .herdrFont(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("first-mate-pr-empty-\(surface.accessibilitySuffix)")
            } else {
                ForEach(pullRequests) { link in
                    FirstMateProminentLinkRow(store: store, link: link, surface: surface)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(FirstMatePalette(scheme: scheme).accent)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .accessibilityIdentifier("first-mate-pr-section-\(surface.accessibilitySuffix)")
    }
}

private struct FirstMateProminentLinkRow: View {
    @Bindable var store: FirstMateStore
    let link: FirstMateLink
    let surface: FirstMateLinkSurface
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(link.title.isEmpty ? link.url : link.title)
                    .herdrFont(.subheadline, weight: .semibold)
                    .accessibilityIdentifier("first-mate-pr-\(surface.accessibilitySuffix)-title-\(link.id)")
                if let host = link.hostLabel {
                    Label(host, systemImage: "globe").herdrFont(.caption2).foregroundStyle(.secondary)
                }
                Text(link.url).herdrFont(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                if let provenance = link.provenanceSummary {
                    Text(provenance).herdrFont(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            FirstMateLinkActionsView(link: link, actionPrefix: "first-mate-pr-\(surface.accessibilitySuffix)-", copied: $copied)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("first-mate-pr-\(surface.accessibilitySuffix)-\(link.id)")
    }
}

/// The Links sub-tab inside the existing Documents inspector.
struct FirstMateLinksView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    @State private var draft = FirstMateLinkDraft()
    @State private var classification = FirstMateLinkClassification.automatic
    @State private var showHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            addForm
            linkGroup(title: "Pull requests", links: snapshot.pullRequestLinks, empty: "No pull request links yet.", prefix: "first-mate-link-pr-")
            linkGroup(title: "Other links", links: snapshot.otherLinks, empty: "No other links saved yet.", prefix: "first-mate-link-other-")
            if showHidden {
                linkGroup(title: "Hidden links", links: snapshot.hiddenLinks, empty: "No hidden links.", prefix: "first-mate-link-hidden-")
            }
            Toggle("Show hidden", isOn: $showHidden)
                .toggleStyle(.switch)
                .herdrFont(.caption)
                .accessibilityIdentifier("first-mate-links-show-hidden")
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD A LINK").herdrFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            TextField("https://…", text: $draft.url)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("first-mate-link-add-url")
            TextField("Optional title", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("first-mate-link-add-title")
            Picker("Classification", selection: $classification) {
                ForEach(FirstMateLinkClassification.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)
            .accessibilityIdentifier("first-mate-link-add-kind")
            HStack(spacing: 10) {
                Button("Add link") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSavingLink || draft.isEmpty || !store.canManageLinks || !store.canMutateLinks)
                    .accessibilityIdentifier("first-mate-link-add-submit")
                if store.isSavingLink {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("first-mate-link-add-busy")
                }
            }
            if let failure = store.linkMutationError {
                Text(failure)
                    .herdrFont(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-link-error")
            } else if !store.canManageLinks {
                Text(FirstMateStore.linksUpgradeMessage)
                    .herdrFont(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-link-unsupported")
            }
        }
        .padding(14)
        .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func linkGroup(title: String, links: [FirstMateLink], empty: String, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).herdrFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if links.isEmpty {
                Text(empty).herdrFont(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(links) { link in
                    FirstMateLinkRow(store: store, link: link, actionPrefix: prefix)
                    Divider()
                }
            }
        }
        .accessibilityIdentifier("\(prefix)group")
    }

    private func save() {
        let context = store.operationContext
        let pending = FirstMateLinkDraft(url: draft.url, title: draft.title, kind: classification.kind)
        Task {
            guard await store.saveLink(pending, expectedContext: context) else { return }
            draft = FirstMateLinkDraft()
            classification = .automatic
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
                .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(link.title.isEmpty ? link.url : link.title)
                    .herdrFont(.subheadline, weight: .medium)
                    .accessibilityIdentifier("\(actionPrefix)title-\(link.id)")
                if let host = link.hostLabel {
                    Text(host).herdrFont(.caption2).foregroundStyle(.secondary)
                }
                Text(link.url).herdrFont(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                HStack(spacing: 8) {
                    if let provenance = link.provenanceSummary {
                        Text(provenance).herdrFont(.caption2).foregroundStyle(.tertiary)
                    }
                    if link.hidden {
                        Label("Hidden", systemImage: "eye.slash")
                            .herdrFont(.caption2).foregroundStyle(.secondary)
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
            .buttonStyle(.bordered)
            .controlSize(.small)
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
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
