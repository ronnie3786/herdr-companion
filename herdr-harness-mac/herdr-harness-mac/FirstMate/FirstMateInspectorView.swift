import SwiftUI

/// The inspector column (MonoCode's `.fm-insp`): underline tabs, a scrolling
/// body, and a 32pt sync footer.
struct FirstMateInspectorView: View {
    @Bindable var store: FirstMateStore
    var snapshot: FirstMateSnapshot? = nil
    var openCommit: ((FirstMateGitCommitSelection) -> Void)? = nil
    var openGit: (() -> Void)? = nil
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    private var featureID: String? { store.selectedFeatureID ?? snapshot?.feature.id }
    private var readKey: String { "\(store.lifecycle.opaqueID)|\(store.inspectorRefreshRevision)|\(featureID ?? "")|\(store.inspectorReadView.rawValue)|\(controlActiveState == .key)|\(scenePhase == .background)" }
    private var resolved: FirstMateSnapshot? {
        guard let featureID else { return snapshot }
        return store.isDemo ? (snapshot ?? store.snapshots[featureID]) : store.inspectorSnapshot(featureID: featureID, view: store.inspectorReadView)
    }
    private var readError: String? {
        featureID.flatMap { store.inspectorErrors[store.inspectorKey(featureID: $0, view: store.inspectorReadView)] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HerdrTabs(
                    selection: $store.inspector,
                    tabs: FirstMateInspector.allCases.map {
                        .init(value: $0, title: $0.rawValue, accessibilityIdentifier: "first-mate-tab-\($0.id)")
                    },
                    style: .underline,
                    accessibilityLabel: "Inspector"
                )
                Spacer(minLength: 0)
                if let openGit {
                    Button("Open Git in New Window", systemImage: "arrow.triangle.branch") { openGit() }
                        .buttonStyle(FirstMateGitIconButtonStyle(palette: palette))
                        .help("Open Git in New Window")
                        .accessibilityLabel("Open Git in New Window")
                        .accessibilityIdentifier("first-mate-inspector-open-git")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: HerdrTheme.ControlHeight.bar)
            .herdrHairline(.bottom, color: palette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let snapshot = resolved {
                        switch store.inspector {
                        case .overview: FirstMateOverviewView(store: store, snapshot: snapshot)
                        case .agents: FirstMateAgentsView(store: store, snapshot: snapshot)
                        case .documents: FirstMateDocumentsView(store: store, snapshot: snapshot)
                        case .workflow: FirstMateWorkflowView(store: store, snapshot: snapshot, openCommit: openCommit)
                        }
                    } else if let readError {
                        Text(readError).foregroundStyle(palette.secondaryText)
                        Button("Retry") { Task { await refresh() } }
                    } else {
                        ProgressView("Loading \(store.inspector.rawValue)…")
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Image(systemName: readError != nil ? "exclamationmark.circle" : resolved == nil ? "clock" : "checkmark.circle")
                    .herdrFont(size: 12)
                    .foregroundStyle(palette.iconTint)
                    .accessibilityHidden(true)
                Text(store.isDemo ? "Synthetic data · no agents launched" : readError != nil ? "Connection needs attention" : resolved == nil ? "Loading from companion…" : "Synced with companion")
                    .lineLimit(1)
                Spacer()
                Text(resolved.map { "Revision \($0.feature.revision)" } ?? "")
                    .monospacedDigit()
            }
            .herdrFont(size: HerdrTheme.TextSize.caption)
            .foregroundStyle(palette.tertiaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: HerdrTheme.ControlHeight.row)
            .herdrHairline(.top, color: palette.hairline)
        }
        .task(id: readKey) {
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(scenePhase == .background ? 30 : controlActiveState == .key ? 10 : 20)) } catch { return }
            } while !Task.isCancelled && !store.isDemo
        }
        .herdrPaneBackground(palette.background)
        .herdrHairline(.leading, color: palette.hairline)
    }
    private func refresh() async {
        guard let featureID else { return }
        await store.refreshInspector(featureID: featureID, view: store.inspectorReadView)
    }
}
