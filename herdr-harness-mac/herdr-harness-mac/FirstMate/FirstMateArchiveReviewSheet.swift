import SwiftUI

struct FirstMateArchiveReviewSheet: View {
    let store: FirstMateStore
    var onArchived: () -> Void = {}
    @State private var model: FirstMateArchiveModel
    @State private var showsReport = false
    @Environment(\.dismiss) private var dismiss

    init(store: FirstMateStore, feature: FirstMateFeature) {
        self.store = store
        _model = State(initialValue: FirstMateArchiveModel(store: store, feature: feature))
    }

    init(store: FirstMateStore, model: FirstMateArchiveModel, onArchived: @escaping () -> Void = {}) {
        self.onArchived = onArchived
        self.store = store
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.phase == .loading {
                        ProgressView("Checking resources and estimating space…")
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if model.phase == .review {
                        FirstMateArchiveReviewContent(model: model)
                    } else {
                        FirstMateArchiveProgressView(cleanup: model.cleanup, logs: model.logs, isWorking: model.isBlocking)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HerdrTheme.alert).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer.padding(20)
                .background(HerdrTheme.railBackground.opacity(0.45))
                .herdrHairline(.top)
        }
        .herdrFont(size: 13)
        .foregroundStyle(HerdrTheme.text)
        .modifier(FirstMateArchiveSurface())
        .tint(HerdrTheme.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 680, idealWidth: 720, maxWidth: 900, minHeight: 580, idealHeight: 720, maxHeight: 900)
        .interactiveDismissDisabled(model.isBlocking)
        .onChange(of: model.archiveID) { _, id in if id != nil { onArchived() } }
        .task { if model.preview == nil { await model.load() } }
        .sheet(isPresented: $showsReport) {
            FirstMateArchiveReportView(store: store, featureID: model.feature.id, archiveID: model.archiveID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-archive-review")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 46, height: 46)
                .background(HerdrTheme.accent.opacity(0.10), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(headerTitle).herdrFont(size: 22, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Text(model.feature.title).lineLimit(2)
                    if let ticket = model.feature.workItemID, !ticket.isEmpty {
                        Text(ticket).herdrFont(size: 11, weight: .medium)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(HerdrTheme.chipFill, in: .rect(cornerRadius: 5))
                    }
                }
                .foregroundStyle(HerdrTheme.secondaryText).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .loading, .review: "Archive session"
        case .finished, .interrupted: "Archive results"
        case .submitting, .running: "Archiving session"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.phase == .review, model.preview != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ByteCountFormatter.string(fromByteCount: model.estimatedBytes, countStyle: .file) + (model.hasUnknownSize ? " + unknown" : ""))
                        .herdrFont(size: 18, weight: .semibold).monospacedDigit()
                        .accessibilityIdentifier("first-mate-archive-space-estimate")
                    Text("Estimated reclaim · \(model.selectedCount) selected")
                        .herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
                }
            } else if model.cleanup?.historyAvailable == true {
                Button("View saved record", systemImage: "doc.text") { showsReport = true }
                    .buttonStyle(HerdrButtonStyle(kind: .outline))
                    .disabled(model.isBlocking)
            }
            Spacer(minLength: 0)
            if model.isBlocking {
                ProgressView().controlSize(.small)
                Text("Keep this window open")
                    .foregroundStyle(HerdrTheme.secondaryText)
            } else {
                Button(model.phase == .finished || model.phase == .interrupted ? "Close" : "Cancel", role: .cancel) {
                    dismiss()
                    Task { await store.refresh() }
                }
                .buttonStyle(HerdrButtonStyle(kind: .ghost))
                .keyboardShortcut(.cancelAction)
            }
            if model.phase == .review {
                if model.preview == nil || model.error != nil {
                    Button("Reload preview") { Task { await model.load() } }
                        .buttonStyle(HerdrButtonStyle(kind: .outline))
                }
                Button(model.confirmTitle, role: model.selectedCount > 0 ? .destructive : nil) {
                    Task { await model.submit() }
                }
                .buttonStyle(HerdrButtonStyle(kind: .primary))
                .disabled(!model.canConfirm)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("first-mate-confirm-archive")
            } else if model.phase == .interrupted {
                Button("Resume live status") { Task { await model.resume() } }
                    .buttonStyle(HerdrButtonStyle(kind: .primary))
            }
        }
    }
}
