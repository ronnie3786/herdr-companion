import SwiftUI

struct PRReviewSkillsView: View {
    @Bindable var store: PRReviewStore
    var setAddingSkill: (Bool) -> Void = { _ in }

    private let groups: [(String, PRReviewSkillKind)] = [
        ("Review", .review),
        ("Explainer videos", .explainer),
        ("Utilities", .utility),
        ("Custom", .custom),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HerdrTheme.cardPadding) {
                HStack {
                    Text("Skills").herdrFont(.title2, weight: .semibold)
                    Spacer()
                    Button("Add custom skill…", systemImage: "plus") {
                        store.isAddingSkill = true
                        setAddingSkill(true)
                    }
                    .accessibilityIdentifier("pr-review-add-skill")
                }
                ForEach(groups, id: \.0) { group in
                    let skills = (store.snapshot?.skills ?? []).filter { $0.kind == group.1 }
                    if !skills.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0).herdrFont(.headline)
                            ForEach(skills, id: \.id) { skill in
                                PRReviewSkillRow(store: store, skill: skill)
                            }
                        }
                    }
                }
            }
            .padding(HerdrTheme.pagePadding)
        }
        .background(HerdrTheme.graphite)
        .sheet(isPresented: $store.isAddingSkill, onDismiss: { setAddingSkill(false) }) {
            PRReviewAddSkillSheet(store: store) {
                store.isAddingSkill = false
                setAddingSkill(false)
            }
        }
        .accessibilityIdentifier("pr-review-skills")
    }
}

private struct PRReviewSkillRow: View {
    @Bindable var store: PRReviewStore
    let skill: PRReviewSkillState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.title).herdrFont(.body, weight: .semibold)
                Text(skill.id).herdrFont(.caption, monospaced: true).foregroundStyle(HerdrTheme.mist)
                Text(stateCaption).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Run") { Task { await store.runSkill(skill.id) } }
                    .disabled(skill.running)
                Button(skill.runCount > 0 ? "Mark as not run" : "Mark as ran") {
                    Task { await store.markSkill(skill.id, state: skill.runCount > 0 ? "not_run" : "ran") }
                }
                if !skill.builtin {
                    Button("Remove", role: .destructive) { Task { await store.removeSkill(id: skill.id) } }
                        .disabled(skill.running)
                }
            }
        }
        .padding(10)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier("pr-review-skill-\(skill.id)")
    }

    private var stateCaption: String {
        guard skill.runCount > 0 else { return "Not run" }
        let date = skill.lastRunAt.map { " · last \($0.prefix(10))" } ?? ""
        return "✓ Ran · \(skill.runCount) runs\(date)"
    }
}

private struct PRReviewAddSkillSheet: View {
    @Bindable var store: PRReviewStore
    let dismiss: () -> Void
    @State private var id = ""
    @State private var title = ""
    @State private var kind: PRReviewSkillKind = .custom
    @State private var promptTemplate = ""
    @State private var outputs = ""
    @State private var description = ""

    private var isValidID: Bool {
        id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            Text("Add custom skill").herdrFont(.title2, weight: .semibold)
            TextField("Skill id", text: $id).textFieldStyle(.roundedBorder)
            Text("Use lowercase letters, digits, and hyphens.")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Picker("Kind", selection: $kind) {
                Text("Custom").tag(PRReviewSkillKind.custom)
                Text("Review").tag(PRReviewSkillKind.review)
                Text("Explainer videos").tag(PRReviewSkillKind.explainer)
                Text("Utilities").tag(PRReviewSkillKind.utility)
            }
            TextField("Prompt template", text: $promptTemplate, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Text("Use placeholders such as {number} when the review supplies them.")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            TextField("Outputs, comma-separated globs", text: $outputs).textFieldStyle(.roundedBorder)
            TextField("Description", text: $description, axis: .vertical).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Add skill") {
                    Task {
                        await store.addSkill(
                            id: id,
                            title: title,
                            kind: kind,
                            promptTemplate: promptTemplate,
                            outputs: outputs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                            description: description
                        )
                        dismiss()
                    }
                }
                .disabled(!isValidID || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(HerdrTheme.pagePadding)
        .frame(width: 500)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.graphite)
        .accessibilityIdentifier("pr-review-add-skill-sheet")
    }
}
