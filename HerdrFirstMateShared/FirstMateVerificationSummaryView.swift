import SwiftUI

/// Verification tones reuse each appearance's readable greens, ambers, and
/// reds while staying visually separate from the workflow status badges. The
/// dark appearance deepens nothing: these are deliberately distinct from the
/// HUD workflow tokens, because this evidence is not a workflow status.
enum FirstMateVerificationPalette {
    static func color(for tone: FirstMateVerificationTone, scheme: ColorScheme) -> Color {
        switch tone {
        case .positive:
            scheme == .dark
                ? Color(red: 0.47, green: 0.83, blue: 0.72)
                : Color(red: 0.12, green: 0.43, blue: 0.34)
        case .caution:
            scheme == .dark
                ? Color(red: 0.93, green: 0.75, blue: 0.42)
                : Color(red: 0.55, green: 0.35, blue: 0.05)
        case .negative:
            scheme == .dark
                ? Color(red: 1.0, green: 0.42, blue: 0.42)
                : Color(red: 0.64, green: 0.13, blue: 0.26)
        case .unavailable:
            FirstMatePalette(scheme: scheme).secondaryText
        }
    }
}

/// A human-facing summary of one feature's scoped verification evidence.
///
/// The verdict is shown exactly as the companion assessed it: status, tested
/// revision, and the package-qualified gate set. Missing suites, previously
/// passing suites dropped from the current gate set, failures, stale evidence,
/// and coverage reasons are named. Long lists disclose their remainder instead
/// of silently dropping entries, so a collapsed section still states how many
/// entries it holds.
struct FirstMateVerificationSummaryView: View {
    let verification: FirstMateVerification?
    var isLastReported = false
    var title = "Verification"
    @Environment(\.colorScheme) private var scheme

    private static let collapsedSuiteLimit = 4

    private var presentation: FirstMateVerificationPresentation {
        FirstMateVerificationPresentation(verification: verification, isLastReported: isLastReported)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if isLastReported { lastReportedBadge }
            }
            statusLine
            Text("This evidence is separate from the feature's workflow status.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let tested = presentation.testedRevisionText {
                Text(tested)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel(presentation.testedRevisionAccessibilityText ?? tested)
            }
            if presentation.isVerified && presentation.testedRevisions.isEmpty {
                Label("This verified assessment did not report a tested revision.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(FirstMateVerificationPalette.color(for: .caution, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLastReported {
                Label(presentation.lastReportedNote, systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(FirstMateVerificationPalette.color(for: .caution, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presentation.hasUnrecognizedStatus {
                Label("This companion reported an unrecognized verification status (\(presentation.status.rawValue)); it is not treated as verified.", systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(FirstMateVerificationPalette.color(for: .unavailable, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presentation.hasEvidence {
                if !presentation.coverageReasons.isEmpty { coverageReasons }
                if !presentation.gateSet.isEmpty {
                    suiteSection("Gate set (\(presentation.gateSet.count))", presentation.gateSet)
                }
                if !presentation.missingSuites.isEmpty {
                    suiteSection("Missing suites (\(presentation.missingSuites.count))",
                                 presentation.missingSuites, tone: .caution)
                }
                if !presentation.previouslyGreenMissingSuites.isEmpty {
                    suiteSection("Previously passing suites dropped from the gate set (\(presentation.previouslyGreenMissingSuites.count))",
                                 presentation.previouslyGreenMissingSuites, tone: .caution)
                }
                if !presentation.failingSuites.isEmpty {
                    suiteSection("Failing suites (\(presentation.failingSuites.count))",
                                 presentation.failingSuites, tone: .negative)
                }
                if !presentation.staleEvidence.isEmpty { staleEvidenceSection }
            } else {
                Text(presentation.unavailableNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(presentation.accessibilitySummary)
        .accessibilityIdentifier("first-mate-verification-summary")
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: presentation.statusSymbol)
                .accessibilityHidden(true)
            Text(presentation.statusTitle)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(FirstMateVerificationPalette.color(for: presentation.statusTone, scheme: scheme))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.statusTitle)
        .accessibilityIdentifier("first-mate-verification-status")
    }

    private var lastReportedBadge: some View {
        Text("Last reported")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FirstMateVerificationPalette.color(for: .caution, scheme: scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                FirstMateVerificationPalette.color(for: .caution, scheme: scheme).opacity(0.12),
                in: .rect(cornerRadius: 6)
            )
            .accessibilityIdentifier("first-mate-verification-last-reported")
    }

    private var coverageReasons: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(presentation.coverageReasons.enumerated()), id: \.offset) { _, reason in
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(FirstMateVerificationPalette.color(for: .caution, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var staleEvidenceSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Stale evidence (\(presentation.staleEvidence.count))")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(presentation.staleEvidence.enumerated()), id: \.offset) { _, evidence in
                let revision = evidence.testedRevision.map(FirstMateVerificationPresentation.shortRevision)
                    ?? "unknown revision"
                Text("\(revision) · \(evidence.reason ?? "no longer current")")
                    .font(.footnote)
                    .foregroundStyle(FirstMateVerificationPalette.color(for: .caution, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func suiteSection(_ heading: String, _ suites: [FirstMateVerificationSuite],
                              tone: FirstMateVerificationTone? = nil) -> some View {
        let accent = FirstMateVerificationPalette.color(for: tone ?? .unavailable, scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone == nil ? .secondary : accent)
            suiteRows(Array(suites.prefix(Self.collapsedSuiteLimit)))
            if suites.count > Self.collapsedSuiteLimit {
                DisclosureGroup("Show the remaining \(suites.count - Self.collapsedSuiteLimit) of \(suites.count)") {
                    suiteRows(Array(suites.dropFirst(Self.collapsedSuiteLimit)))
                }
                .font(.footnote)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func suiteRows(_ suites: [FirstMateVerificationSuite]) -> some View {
        ForEach(Array(suites.enumerated()), id: \.offset) { _, suite in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: outcomeSymbol(suite))
                    .font(.caption)
                    .foregroundStyle(outcomeColor(suite))
                    .accessibilityHidden(true)
                Text(suite.displayLabel)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let outcomeTitle = suite.outcomeTitle {
                    Text(outcomeTitle)
                        .font(.caption)
                        .foregroundStyle(outcomeColor(suite))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func outcomeSymbol(_ suite: FirstMateVerificationSuite) -> String {
        if suite.isPassing { return "checkmark.circle" }
        if suite.isFailing { return "xmark.circle" }
        return suite.outcome == "skipped" ? "minus.circle" : "circle"
    }

    private func outcomeColor(_ suite: FirstMateVerificationSuite) -> Color {
        if suite.isPassing { return FirstMateVerificationPalette.color(for: .positive, scheme: scheme) }
        if suite.isFailing { return FirstMateVerificationPalette.color(for: .negative, scheme: scheme) }
        return FirstMateVerificationPalette.color(for: .unavailable, scheme: scheme)
    }
}
