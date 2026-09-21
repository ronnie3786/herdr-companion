import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Car mode markdown")
struct CarModeMarkdownTests {
    @Test("Bold markers are resolved and the emphasis survives")
    func bold() throws {
        let styled = CarMarkdownText.inline("The **demo export** is ready.", size: 20, scale: 1)

        #expect(String(styled.characters) == "The demo export is ready.")
        let run = try #require(styled.runs.first { String(styled[$0.range].characters) == "demo export" })
        #expect(run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    @Test("Italic markers are resolved")
    func italic() throws {
        let styled = CarMarkdownText.inline("The *winter* list", size: 20, scale: 1)

        #expect(String(styled.characters) == "The winter list")
        let run = try #require(styled.runs.first { String(styled[$0.range].characters) == "winter" })
        #expect(run.inlinePresentationIntent?.contains(.emphasized) == true)
    }

    @Test("Inline code keeps its intent and gets the code styling")
    func inlineCode() throws {
        let styled = CarMarkdownText.inline("A `reviewed` column", size: 20, scale: 1)

        #expect(String(styled.characters) == "A reviewed column")
        let run = try #require(styled.runs.first { String(styled[$0.range].characters) == "reviewed" })
        #expect(run.inlinePresentationIntent?.contains(.code) == true)
        #expect(run.font != nil, "Inline code must be visually distinct, not plain prose")
    }

    @Test("Link text is kept and the destination is not shown")
    func links() {
        let styled = CarMarkdownText.inline("Read the [sample table](https://example.invalid/table) next.", size: 20, scale: 1)

        #expect(String(styled.characters) == "Read the sample table next.")
        #expect(!String(styled.characters).contains("https://"))
    }

    @Test("Plain prose passes through unchanged")
    func plainProse() {
        let source = "The demo export is ready."

        #expect(CarMarkdownText.plainText(source) == source)
    }

    @Test("Accessibility text never carries markers, because VoiceOver would read them")
    func plainTextForVoiceOver() {
        #expect(CarMarkdownText.plainText("A `reviewed` column") == "A reviewed column")
        #expect(CarMarkdownText.plainText("*Winter reading* first") == "Winter reading first")
        #expect(CarMarkdownText.plainText("The **demo export** is ready") == "The demo export is ready")
        #expect(CarMarkdownText.plainText("Read the [sample](https://example.invalid) next") == "Read the sample next")
    }

    @Test("Soft-wrapped prose reflows instead of keeping the agent's column width")
    func softWrapNormalization() {
        let wrapped = "The demo export is ready: three fictional books, each with a one-line note and a\nsuggested reading order."

        let flattened = CarMarkdownText.plainText(wrapped)

        #expect(flattened == "The demo export is ready: three fictional books, each with a one-line note and a suggested reading order.")
        #expect(!flattened.contains("\n"))
    }

    @Test("Block-level markers never reach a reader through the parser")
    func blocksStripMarkers() {
        let source = """
        ## Heading

        | name | note |
        | --- | --- |
        | herb | mint |

        - first
        - second

        ```sh
        head -3 reading-list.csv
        ```
        """

        let blocks = PiMarkdownParser.parse(source)
        let prose = blocks.flatMap(proseText).joined(separator: " ")

        #expect(prose.contains("Heading"))
        #expect(prose.contains("first"))
        #expect(!prose.contains("##"))
        #expect(!prose.contains("| ---"))
        #expect(!prose.contains("```"))
        #expect(!prose.contains("---"))
    }

    @Test("The demo fixtures exercise the renderer instead of plain sentences")
    func demoFixturesCarryMarkdown() throws {
        let pane: [String: Any] = [
            "pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1",
            "agent": "Pi", "display_agent": "Pi",
            "title": "Sample reading list export",
            "agent_status": "done", "last_activity_at": "2030-01-01T12:00:00Z",
            "pi_semantic": ["available": true, "connected": true, "protocolVersion": 1, "sessionId": "s1"],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "workspace_id": "w1", "label": "Reading Journal", "panes": [pane],
        ])
        let workspace = try JSONDecoder().decode(HerdrWorkspace.self, from: data).stamped(machineID: "demo1")
        let session = try #require(AgentSession.recent(workspaces: [workspace], machines: [], query: "").first)

        let response = try #require(CarModeDemoData.summary(for: session).response)

        // A fixture without markdown would let a rendering regression pass.
        #expect(response.contains("**"))
        #expect(response.contains("```"))
        #expect(response.contains("|"))
        #expect(response.contains("- "))
    }

    private func proseText(_ block: PiMarkdownBlock) -> [String] {
        switch block {
        case let .paragraph(_, text), let .heading(_, _, text), let .quote(_, text):
            [text]
        case .code:
            []
        case let .list(_, items):
            items.map(\.text)
        case let .table(_, table):
            table.headers + table.rows.flatMap { $0 }
        case .thematicBreak:
            []
        }
    }
}
