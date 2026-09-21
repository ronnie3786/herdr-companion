import Foundation

/// Synthetic Car mode transcripts for `-HerdrDemoMode`.
///
/// Matches the fictional garden, reading, and weather panes in `DemoData`, so
/// demo mode shows real headlines and detail prose without a server. Never
/// captured user work.
enum CarModeDemoData {
    static func summary(for session: AgentSession) -> CarAgentSummary {
        let fixture = fixture(for: session.pane)
        return CarAgentSummary(
            kind: fixture.kind,
            response: fixture.response,
            asked: fixture.asked,
            phase: fixture.phase,
            isBridgeConnected: true
        )
    }

    private struct Fixture {
        let kind: CarAgentSummary.HeadlineKind
        let response: String?
        let asked: String?
        let phase: PiConversationPhase
    }

    private static func fixture(for pane: HerdrPane) -> Fixture {
        switch pane.displayTitle {
        case "Plan a fictitious herb garden":
            Fixture(
                kind: .activity("Running the seed-layout checks · step 4 of 6"),
                response: """
                The sample planting plan is checked in and the layout checks are running now.

                - Mint is boxed into its own trench so it **cannot spread**
                - The dill row is waiting on the *shadow overlap* check
                - Both window boxes still need a watering cadence

                I will report back with the full table when both checks finish.
                """,
                asked: "Lay out a sample herb garden and check the planting plan.",
                phase: .working
            )
        case "Sample reading list export":
            Fixture(
                kind: .answer("The demo export is ready: three fictional books with notes and a reading order."),
                response: """
                The demo export is ready: **three fictional books**, each with a one-line note and a
                suggested reading order.

                ## What is in the export

                - *Winter reading* first, then the summer collection
                - One placeholder title, flagged rather than removed
                - A `reviewed` column that stays empty until you fill it

                ## Suggested order

                | # | Title | Note |
                | --- | --- | --- |
                | 1 | The Sample Almanac | winter |
                | 2 | Fictional Ferns | summer |

                > Nothing was sent anywhere: review the export and I can reshape the columns.

                ```sh
                head -3 reading-list.csv
                ```
                """,
                asked: "Export the example book list as a table I can review.",
                phase: .idle
            )
        case "Validate the example book list":
            Fixture(
                kind: .activity("Reading SampleBookTable.md"),
                response: """
                The example book list validates against the demo schema.

                1. Three entries, with no duplicate identifiers
                2. Every note is under the sample length limit
                3. One placeholder title is flagged, not removed
                """,
                asked: "Validate the example book list and flag anything odd.",
                phase: .working
            )
        case "Choose sample garden colors":
            Fixture(
                kind: .question("Waiting for your answer: which sample garden palette should the demo use?"),
                response: """
                The demo palette needs one decision before I can finish: the **muted herb** palette
                or the brighter *kitchen-garden* one.
                """,
                asked: "Pick sample colors for the garden demo.",
                phase: .idle
            )
        default:
            Fixture(
                kind: .idle,
                response: """
                The sample postcard sketch is saved with three border options, and I stopped there \
                as you asked.
                """,
                asked: "Sketch a sample postcard border and stop there.",
                phase: .idle
            )
        }
    }
}
