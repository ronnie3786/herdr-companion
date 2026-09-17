import SwiftUI

struct ResponseBriefCardView: View {
    let record: ResponseBriefPersistence.Record
    let openDetail: (ResponseBrief.Detail, ResponseBriefPersistence.Record) -> Void

    static func defaultVisibleGeneratedStrings(
        for record: ResponseBriefPersistence.Record
    ) -> [String] {
        guard record.brief.conformsToConcisionPolicy(source: record.source.text) else { return [] }
        return record.brief.visibleGeneratedStrings
    }

    @ViewBuilder
    var body: some View {
        if record.brief.conformsToConcisionPolicy(source: record.source.text) {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.brief.summary)
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.text)
                    .textSelection(.enabled)

                if !record.brief.points.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(record.brief.points) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(HerdrTheme.accent)
                                    .accessibilityHidden(true)
                                Text(point.text)
                                    .herdrFont(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !record.brief.details.isEmpty {
                    Divider().overlay(HerdrTheme.separator)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(record.brief.details) { detail in
                            Button(detail.label, systemImage: detail.kind.systemImage) {
                                openDetail(detail, record)
                            }
                            .buttonStyle(.link)
                            .accessibilityHint("Opens exact lines \(detail.startLine) through \(detail.endLine) from the original response")
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .stroke(HerdrTheme.accent.opacity(0.25), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AI rewritten response brief")
            .accessibilityHint("A concise rendition of response \(record.source.responseID); full source is available nearby")
            .help("AI rewritten from response \(record.source.responseID)")
        } else {
            Label("This saved brief needs regeneration.", systemImage: "arrow.clockwise.circle")
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("response-brief-regenerate-needed")
        }
    }
}

private extension ResponseBrief.Detail.Kind {
    var systemImage: String {
        switch self {
        case .table: "tablecells"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .detail: "doc.text.magnifyingglass"
        }
    }
}
