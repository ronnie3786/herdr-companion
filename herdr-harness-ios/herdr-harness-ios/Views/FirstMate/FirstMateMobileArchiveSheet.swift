import SwiftUI

struct FirstMateMobileArchiveSheet: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let request: FirstMateMobileArchiveRequest
    @Environment(\.dismiss) private var dismiss
    @State private var reason: FirstMateArchiveReason?
    @State private var isSubmitting = false
    @State private var isVisible = true
    @State private var error: String?

    private var isCurrent: Bool { request.isCurrent(in: fleet) }
    private var canArchive: Bool {
        isCurrent && model.firstMateCanControl(machineID: request.target.machineID)
            && request.store.archiveSupported && !request.store.isSending
            && !request.store.isSubmitting(featureID: request.target.featureID) && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HerdrMicroLabel(text: "Archive conversation")
                        Text(request.name).herdrFont(.headline).foregroundStyle(HerdrTheme.primaryText)
                        Text(request.machineName).herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                        Text(["running", "coordinating", "recovering"].contains(request.feature.status)
                             ? "Work continues after archiving. The feature leaves the active list; its status, agents, documents and saved sessions are retained."
                             : "The feature leaves the active list. Its status, agents, documents and saved sessions are retained.")
                            .herdrFont(.body).foregroundStyle(HerdrTheme.proseText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).herdrCard()

                    VStack(alignment: .leading, spacing: 4) {
                        HerdrMicroLabel(text: "Optional reason")
                        reasonButton(nil, title: "No reason")
                        ForEach(FirstMateArchiveReason.allCases) { value in reasonButton(value, title: value.title) }
                    }
                    .padding(16).herdrCard()
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .herdrFont(.body).foregroundStyle(HerdrTheme.warning)
                            .accessibilityIdentifier("first-mate-archive-error")
                    }
                    Button(isSubmitting ? "Archiving…" : "Archive", action: submit)
                        .buttonStyle(HerdrButtonStyle(kind: .primary))
                        .disabled(!canArchive)
                        .accessibilityIdentifier("first-mate-confirm-archive")
                        .composerLayoutMeasurement(id: "archive-submit-control")
                }
                .padding(20)
            }
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
            .navigationTitle("Archive feature?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSubmitting)
                }
            }
        }
        .herdrFirstMateChrome()
        .tint(HerdrTheme.accent)
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: isCurrent, initial: true) { _, current in if !current { dismiss() } }
        .onDisappear { isVisible = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-archive-sheet")
    }

    private func reasonButton(_ value: FirstMateArchiveReason?, title: String) -> some View {
        Button { reason = value } label: {
            HStack {
                Text(title).herdrFont(.body).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: reason == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reason == value ? HerdrTheme.accent : HerdrTheme.iconTint)
            }
            .foregroundStyle(HerdrTheme.primaryText)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 44).herdrRowBackground(selected: reason == value)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityAddTraits(reason == value ? .isSelected : [])
        .accessibilityIdentifier("first-mate-archive-reason-" + (value?.rawValue ?? "none"))
    }

    private func submit() {
        guard canArchive else { return }
        let submittedReason = reason
        isSubmitting = true
        error = nil
        Task {
            let archived = await fleet.setArchived(request.target, archived: true, reason: submittedReason,
                                                   expectedContext: request.context)
            guard isVisible else { return }
            isSubmitting = false
            guard fleet.store(for: request.target) === request.store,
                  request.store.lifecycle == request.context.lifecycleIdentity else { dismiss(); return }
            if archived { dismiss() }
            else { error = request.store.error ?? "The conversation could not be archived. It remains available." }
        }
    }
}
