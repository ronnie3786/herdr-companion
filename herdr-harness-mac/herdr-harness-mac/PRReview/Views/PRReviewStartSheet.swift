import SwiftUI

struct PRReviewStartSheet: View {
    @Bindable var store: PRReviewStore
    let dismiss: () -> Void
    @State private var selectedSkills: Set<String> = []

    private static let selectionKey = "herdr.prReview.lastSkills"
    private var skills: [PRReviewSkill] { store.capabilities?.skills ?? PRReviewDemo.snapshot().skills.map(\.skill) }

    var body: some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            Text("Start PR review").herdrFont(.title2, weight: .semibold)
            TextField("Pull request link", text: .constant(store.pendingURL ?? ""))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            ForEach([.review, .explainer, .utility, .custom] as [PRReviewSkillKind], id: \.self) { kind in
                let group = skills.filter { $0.kind == kind }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind.title).herdrFont(.headline)
                        ForEach(group) { skill in
                            Toggle(skill.title, isOn: binding(for: skill.id))
                                .herdrFont(.callout)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Add without running") { submit(skillIDs: []) }
                Button("Start review") { submit(skillIDs: Array(selectedSkills)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HerdrTheme.pagePadding)
        .frame(width: 480)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.graphite)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("pr-review-start-sheet")
        .onAppear { selectedSkills = Self.loadSelection() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selectedSkills.contains(id) }, set: { selected in
            if selected { selectedSkills.insert(id) } else { selectedSkills.remove(id) }
        })
    }

    private func submit(skillIDs: [String]) {
        Self.saveSelection(selectedSkills)
        guard let url = store.pendingURL else { dismiss(); return }
        Task {
            await store.create(url: url, skillIDs: skillIDs)
            store.pendingURL = nil
            dismiss()
        }
    }

    static func loadSelection(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: selectionKey) ?? [])
    }

    static func saveSelection(_ selection: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(selection.sorted(), forKey: selectionKey)
    }
}

private extension PRReviewSkillKind {
    var title: String {
        switch self {
        case .review: "Review"
        case .explainer: "Explainer videos"
        case .utility: "Utilities"
        case .custom: "Custom"
        case .unknown: "Other"
        }
    }
}
