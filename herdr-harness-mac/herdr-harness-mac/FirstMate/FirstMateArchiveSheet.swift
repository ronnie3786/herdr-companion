import SwiftUI

/// Reuses the feature archive action from conversations and saved sessions.
struct FirstMateArchiveContextMenu: ViewModifier {
    @Bindable var store: FirstMateStore
    let feature: FirstMateFeature
    let canControl: Bool
    @State private var archiveCandidate: FirstMateFeature?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Archive feature…", systemImage: "archivebox") { archiveCandidate = feature }
                    .disabled(!canControl || !store.archiveSupported || store.isSending || feature.isArchived)
            }
            .sheet(item: $archiveCandidate) { feature in
                FirstMateArchiveSheet(store: store, feature: feature)
            }
    }
}

/// One entry point for both the main shell and the standalone First Mate window.
struct FirstMateArchiveSheet: View {
    enum Flow { case review, visibilityOnly, updateRequired }

    static func flow(status: String, supportsCleanup: Bool, supportsReview: Bool) -> Flow {
        guard status == "completed" else { return .visibilityOnly }
        if supportsReview { return .review }
        return supportsCleanup ? .updateRequired : .visibilityOnly
    }

    let store: FirstMateStore
    let feature: FirstMateFeature
    @Environment(\.dismiss) private var dismiss
    var isConnectionCurrent: () -> Bool = { true }
    var onArchived: () -> Void = {}
    @State private var lifecycle: FirstMateStore.LifecycleIdentity?
    @State private var isReady = false
    @State private var demoModel: FirstMateArchiveModel?

    var body: some View {
        Group {
            if let demoModel {
                FirstMateArchiveReviewSheet(store: store, model: demoModel, onArchived: onArchived)
            } else if !isReady {
                ProgressView("Checking this companion…").padding(32).frame(width: 480)
            } else if Self.flow(status: feature.status, supportsCleanup: store.archiveCleanupSupported,
                                supportsReview: store.archiveReviewSupported) == .review {
                FirstMateArchiveReviewSheet(store: store,
                    model: .init(store: store, feature: feature, isConnectionCurrent: isConnectionCurrent),
                    onArchived: onArchived)
            } else if Self.flow(status: feature.status, supportsCleanup: store.archiveCleanupSupported,
                                supportsReview: store.archiveReviewSupported) == .updateRequired {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Companion update required", systemImage: "arrow.down.circle")
                        .herdrFont(size: 18, weight: .semibold)
                    Text("Update this session’s companion to review resources and retention before archiving.")
                        .foregroundStyle(HerdrTheme.secondaryText)
                    Button("Close", role: .cancel) { dismiss() }
                }
                .padding(24).frame(width: 480).modifier(FirstMateArchiveSurface())
            } else {
                FirstMateArchiveConfirmation(feature: feature,
                    canArchive: store.archiveSupported && !store.isSending && connectionIsCurrent) { reason in
                    guard connectionIsCurrent else { return "The connection changed. Reopen Archive on this feature." }
                    guard await store.setArchived(featureID: feature.id, archived: true, reason: reason) else {
                        return store.error ?? "Could not archive this feature. Try again."
                    }
                    onArchived()
                    return nil
                }
                .modifier(FirstMateArchiveSurface())
            }
        }
        .preferredColorScheme(.dark)
        .task {
            #if DEBUG
            if store.isDemo, feature.status == "completed",
               ProcessInfo.processInfo.arguments.contains("-HerdrDemoMode"),
               ProcessInfo.processInfo.arguments.contains("-HerdrArchiveDemo") {
                demoModel = FirstMateArchiveDemo.makeModel(feature: feature) {
                    _ = await store.setArchived(featureID: feature.id, archived: true)
                }
            }
            #endif
            lifecycle = store.lifecycle
            if !store.hasLoaded { await store.refresh() }
            isReady = true
        }
    }

    private var connectionIsCurrent: Bool { lifecycle == store.lifecycle && isConnectionCurrent() }
}

struct FirstMateArchiveConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let feature: FirstMateFeature
    var canArchive = true
    let archive: (FirstMateArchiveReason?) async -> String?
    @State private var reason: FirstMateArchiveReason?
    @State private var isArchiving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Archive \(feature.title)?").herdrFont(size: 15, weight: .semibold)
            Text("This feature will leave your active list. Its conversation and session history are kept, and any running work continues. To restore it, select its machine and turn on Show archived.")
                .herdrFont(size: HerdrTheme.TextSize.body)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Optional reason", selection: $reason) {
                Text("No reason").tag(nil as FirstMateArchiveReason?)
                ForEach(FirstMateArchiveReason.allCases) { value in
                    Text(value.title).tag(value as FirstMateArchiveReason?)
                }
            }
            if let error {
                Text(error).foregroundStyle(HerdrTheme.warning).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(isArchiving)
                Button("Archive", systemImage: "archivebox") {
                    isArchiving = true
                    Task {
                        error = await archive(reason)
                        isArchiving = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(!canArchive || isArchiving)
                .accessibilityIdentifier("first-mate-confirm-archive")
            }
        }
        .interactiveDismissDisabled(isArchiving)
        .controlSize(.large)
        .padding(20)
        .frame(width: 480)
    }
}

struct FirstMateSessionArchiveMenu: ViewModifier {
    @Bindable var store: FirstMateStore
    let session: FirstMateSession

    @ViewBuilder
    func body(content: Content) -> some View {
        if let feature = store.features.first(where: { $0.id == session.featureID }) {
            content.modifier(FirstMateArchiveContextMenu(store: store, feature: feature,
                                                       canControl: store.controlAvailable || store.isDemo))
        } else {
            content
        }
    }
}
