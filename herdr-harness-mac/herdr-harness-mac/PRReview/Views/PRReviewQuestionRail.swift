import SwiftUI

struct PRReviewQuestionRail: View {
    let questions: [PRReviewQuestionHistory.Question]
    let baseSHA: String
    let headSHA: String
    var open: (PRReviewQuestionHistory.Question) -> Void
    var compact = false

    var body: some View {
        Group {
            if compact {
                Menu("Saved questions · \(questions.count)", systemImage: "bubble.left.and.bubble.right") {
                    ForEach(questions) { question in
                        Button(question.prompt) { open(question) }
                            .help(question.context.items.first?.label ?? question.path)
                    }
                }
                .herdrFont(.caption).menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(HerdrTheme.ink)
            } else {
                expandedRail
            }
        }
        .accessibilityIdentifier("pr-review-saved-questions")
    }

    private var expandedRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Saved questions · \(questions.count)", systemImage: "bubble.left.and.bubble.right")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(questions) { question in
                        Button { open(question) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(question.prompt).herdrFont(.callout).lineLimit(2)
                                Text(question.context.items.first?.label ?? question.path)
                                    .herdrFont(.caption2).foregroundStyle(HerdrTheme.mist).lineLimit(1)
                                if question.baseSHA != baseSHA || question.headSHA != headSHA {
                                    Label("Earlier revision · \(question.headSHA.prefix(8))", systemImage: "clock")
                                        .herdrFont(.caption2).foregroundStyle(HerdrTheme.working)
                                }
                            }
                            .frame(width: 240, alignment: .leading)
                            .padding(10)
                            .background(HerdrTheme.elevated, in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.herdrPlain)
                        .help("Reopen the saved answer and continue this conversation")
                        .accessibilityIdentifier("pr-review-question-\(question.id)")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(HerdrTheme.ink)
    }
}
