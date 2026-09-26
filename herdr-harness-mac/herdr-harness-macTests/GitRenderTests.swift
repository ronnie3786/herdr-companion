import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Offscreen renders of the native Git workbench (demo mode, the Git window
/// and First Mate's demo target) at the design study's pane size, at the
/// largest text size, and at a narrow width. PNGs land beside the other
/// render suites' output (see `HerdrRenderHarness.directory`).
@Suite("Git workbench renders", .serialized)
@MainActor
struct GitRenderTests {
    /// The study's Git pane (window minus the 260pt sidebar and title bar).
    static let pane = CGSize(width: 1020, height: 760)

    @Test("Demo Git workbench at the study's pane size")
    func demoPane() async throws {
        let result = try await render("git-workspace-pane.png", size: Self.pane)
        result.expectSubstantial()
    }

    @Test("Every diff row type: deletions, additions, a fold and a second hunk")
    func everyRowType() async throws {
        let result = try await render("git-workspace-rows.png", size: Self.pane, diff: GitRenderFixtures.gardenCanvasDiff)
        result.expectSubstantial()
    }

    @Test("Largest text size (160%) keeps rows and gutters in proportion")
    func largestText() async throws {
        let result = try await render(
            "git-workspace-xxxlarge.png",
            size: Self.pane,
            diff: GitRenderFixtures.gardenCanvasDiff,
            fontScale: .xxxLarge
        )
        result.expectSubstantial()
    }

    @Test("Narrow pane keeps names readable and the diff scrollable")
    func narrowPane() async throws {
        let result = try await render(
            "git-workspace-narrow.png",
            size: CGSize(width: 620, height: 560),
            diff: GitRenderFixtures.gardenCanvasDiff
        )
        result.expectSubstantial()
    }

    @Test("First Mate Git keeps its context bar readable in dark and light", arguments: [ColorScheme.dark, .light])
    func firstMateGit(scheme: ColorScheme) async throws {
        let model = HerdrRenderFixtures.demoModel()
        let result = try await HerdrRenderHarness.render(
            "git-first-mate-\(scheme == .dark ? "dark" : "light").png",
            size: Self.pane
        ) {
            FirstMateGitView(
                model: model,
                machineID: "demo",
                featureID: "demo-feature",
                featureTitle: "Fictional garden planner",
                configuration: nil,
                configurationRevision: 0,
                popOut: { _ in }
            )
            .environment(\.colorScheme, scheme)
        }
        result.expectSubstantial()
    }

    // MARK: - Diff parsing

    @Test("Diff rows hide Git metadata, number both sides and fold the gap between hunks")
    func parsesRows() {
        let parsed = WorkspaceGitDiffParser.parse(GitRenderFixtures.gardenCanvasDiff, file: "Sources/Garden/GardenCanvas.swift")
        #expect(parsed.additions == 5)
        #expect(parsed.deletions == 1)
        #expect(!parsed.rows.contains { $0.text.hasPrefix("diff --git") || $0.text.hasPrefix("index ") })

        let kinds = parsed.rows.map(\.kind)
        #expect(kinds.first == .hunk)
        #expect(kinds.contains(.fold(18)), "Old lines 48 through 65 sit between the two hunks")
        #expect(kinds.filter { $0 == .hunk }.count == 2)

        let deletion = parsed.rows.first { $0.kind == .deletion }
        #expect(deletion?.number == 44, "Deletions show the old line number")
        #expect(deletion?.text.trimmingCharacters(in: .whitespaces) == "tint: .green,")
        let additions = parsed.rows.filter { $0.kind == .addition }.compactMap(\.number)
        #expect(additions == [44, 45, 46, 69, 70], "Additions show the new line number")
        let lastContext = parsed.rows.last { $0.kind == .context }
        #expect(lastContext?.number == 71)
        #expect(parsed.rows.first { $0.kind == .addition }?.accessibilityLabel.hasPrefix("Added line 44:") == true)
    }

    @Test("Untracked files, empty diffs and multi-file patches keep readable rows")
    func parsesEdgeCases() {
        let untracked = WorkspaceGitDiffParser.parse("""
        diff --git a/Notes.md b/Notes.md
        new file mode 100644
        --- /dev/null
        +++ b/Notes.md
        @@ -0,0 +1,2 @@
        +# Fictional notes
        +Water the basil.
        \\ No newline at end of file
        """, file: "Notes.md")
        #expect(untracked.rows.map(\.kind) == [.note, .hunk, .addition, .addition, .marker])
        #expect(untracked.rows.first?.text == "new file mode 100644")
        #expect(untracked.rows.allSatisfy { $0.highlighted == nil }, "Prose files stay plain")

        let empty = WorkspaceGitDiffParser.parse("(empty diff)", file: "Seeds.swift")
        #expect(empty.rows.map(\.kind) == [.note])

        let twoFiles = WorkspaceGitDiffParser.parse("""
        @@ -1 +1 @@
        -let a = 1
        +let a = 2
        diff --git a/B.swift b/B.swift
        @@ -9 +9 @@
        -let b = 1
        +let b = 2
        """, file: "A.swift")
        #expect(!twoFiles.rows.contains { if case .fold = $0.kind { true } else { false } },
                "A new file section never folds against the previous file")
        #expect(twoFiles.rows.filter { $0.kind == .deletion }.map(\.number) == [1, 9])
    }

    @Test("Swift rows get MonoCode's syntax colors")
    func highlightsSwift() {
        let line = "    private func selectSamplePlant() { // Keep \"basil\" 42"
        let highlighted = WorkspaceGitSyntax.highlight(line, language: .cFamily)
        #expect(String(highlighted.characters) == line, "Highlighting never changes the text")
        let colored = highlighted.runs.compactMap { run -> (String, Color)? in
            guard let color = run.swiftUI.foregroundColor else { return nil }
            return (String(highlighted[run.range].characters), color)
        }
        #expect(colored.contains { $0.0 == "private" && $0.1 == HerdrTheme.Syntax.keyword })
        #expect(colored.contains { $0.0 == "selectSamplePlant" && $0.1 == HerdrTheme.Syntax.callable })
        #expect(colored.contains { $0.0.hasPrefix("// Keep") && $0.1 == HerdrTheme.Syntax.comment })
    }

    // MARK: - Contrast

    /// Every Git text color the restyle introduces, on the surface it sits on
    /// (translucent fills composited over opaque `base`).
    @Test("Git text colors clear 4.5:1 on their rows")
    func gitContrast() throws {
        let base = HerdrTheme.windowBackground
        let selected = HerdrWebTheme.over(HerdrTheme.selectedFill, base)
        let hovered = HerdrWebTheme.over(HerdrTheme.hoverFill, base)
        let header = HerdrWebTheme.over(HerdrTheme.inkFill(0.02), base)
        let hunk = HerdrWebTheme.over(HerdrTheme.insetFill, base)
        let fold = HerdrWebTheme.over(HerdrTheme.chipFill, base)
        let addRow = HerdrWebTheme.over(HerdrTheme.diffAddRow, base)
        let removeRow = HerdrWebTheme.over(HerdrTheme.diffRemoveRow, base)
        let alertCard = HerdrWebTheme.over(HerdrTheme.alert.opacity(0.08), base)
        let pairs: [(String, Color, Color)] = [
            ("branch", HerdrTheme.primaryText, base),
            ("changed", HerdrTheme.working, base),
            ("clean", HerdrTheme.success, base),
            ("path", HerdrTheme.tertiaryText, base),
            ("section label", HerdrTheme.tertiaryText, base),
            ("folder on selected row", HerdrTheme.tertiaryText, selected),
            ("folder on hovered row", HerdrTheme.tertiaryText, hovered),
            ("name on selected row", HerdrTheme.primaryText, selected),
            ("commit hash", HerdrTheme.tertiaryText, base),
            ("summary label", HerdrTheme.secondaryText, base),
            ("add count", HerdrTheme.diffAdd, base),
            ("remove count", HerdrTheme.diffRemove, base),
            ("add count in header", HerdrTheme.diffAdd, header),
            ("remove count in header", HerdrTheme.diffRemove, header),
            ("file path", HerdrTheme.inkSolid(0.85), header),
            ("hunk text", HerdrTheme.diffHunk, hunk),
            ("fold text", HerdrTheme.tertiaryText, fold),
            ("context number", HerdrTheme.tertiaryText, base),
            ("context code", HerdrTheme.secondaryText, base),
            ("added code", HerdrTheme.inkSolid(0.80), addRow),
            ("removed code", HerdrTheme.inkSolid(0.80), removeRow),
            ("added number", HerdrTheme.diffAddNumber, HerdrWebTheme.over(HerdrTheme.diffAddGutter, addRow)),
            ("removed number", HerdrTheme.diffRemoveNumber, HerdrWebTheme.over(HerdrTheme.diffRemoveGutter, removeRow)),
            ("error title", HerdrTheme.alert, alertCard),
            ("error detail", HerdrTheme.secondaryText, alertCard),
            ("swift glyph", HerdrTheme.Syntax.type, selected),
        ]
        for letter in ["M", "?", "A", "D"] {
            let color = GitStatusLetter.color(for: letter)
            #expect(contrast(color, selected) >= 4.5, "\(letter) on a selected row")
            #expect(contrast(color, hovered) >= 4.5, "\(letter) on a hovered row")
        }
        for (name, text, surface) in pairs {
            let ratio = contrast(text, surface)
            #expect(ratio >= 4.5, "\(name) was \(ratio):1")
        }
    }

    // MARK: - Helpers

    private func contrast(_ first: Color, _ second: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let value = HerdrTheme.resolved(color)
            func linear(_ channel: CGFloat) -> Double {
                let c = Double(channel)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(value.redComponent) + 0.7152 * linear(value.greenComponent)
                + 0.0722 * linear(value.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func render(
        _ name: String,
        size: CGSize,
        diff: String? = nil,
        fontScale: HerdrFontScale = .medium
    ) async throws -> HerdrRenderHarness.RenderResult {
        let model = HerdrRenderFixtures.demoModel()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        return try await HerdrRenderHarness.render(name, size: size) {
            WorkspaceGitView(
                workspace: workspace,
                loadStatus: { try await model.fetchGitStatus(for: workspace) },
                loadDiff: { file, section in
                    if let diff {
                        return WorkspaceGitDiffResponse(ok: true, file: file, section: section, diff: diff, error: nil)
                    }
                    return try await model.fetchGitDiff(for: workspace, file: file, section: section)
                },
                stageFile: { file in try await model.stageGitFile(file, in: workspace) },
                unstageFile: { file in try await model.unstageGitFile(file, in: workspace) }
            )
            .environment(\.herdrFontScale, fontScale)
        }
    }
}

/// Synthetic content only: a fictional garden app.
enum GitRenderFixtures {
    /// Two hunks with a deletion, additions, context and an 18-line gap.
    static let gardenCanvasDiff = """
    diff --git a/Sources/Garden/GardenCanvas.swift b/Sources/Garden/GardenCanvas.swift
    index 17f4c31..92ab840 100644
    --- a/Sources/Garden/GardenCanvas.swift
    +++ b/Sources/Garden/GardenCanvas.swift
    @@ -40,8 +40,10 @@ struct GardenCanvas: View {
         var body: some View {
             ForEach(plants) { plant in
                 PlantTile(
                     plant: samplePlant,
    -                tint: .green,
    +                color: sampleColor,
    +                isSelected: $isSelected,
    +                select: selectSamplePlant,
                     label: sampleLabel
                 )
             }
    @@ -66,2 +68,4 @@ struct GardenCanvas: View {
         private func selectSamplePlant() {
    +        // Keep the canvas in sync with the picker.
    +        isSelected.toggle()
         }
    """
}
