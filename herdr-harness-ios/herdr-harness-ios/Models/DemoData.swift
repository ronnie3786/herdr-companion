import Foundation

/// Entirely fictional garden, reading, and weather examples; never captured user work.
enum DemoData {
    static let workspaces: [HerdrWorkspace] = [
        workspace(
            id: "w1",
            number: 1,
            label: "Garden Planner",
            path: "/tmp/herdr-demo/garden-planner",
            panes: [
                pane(id: "w1:p1", tabID: "w1:t1", status: .working, title: "Plan a fictional herb garden", agent: "Codex", revision: 184, firstSeenAt: Date().addingTimeInterval(-3_600), lastActivityAt: Date(), workingSince: Date().addingTimeInterval(-47 * 60)),
                pane(id: "w1:p2", tabID: "w1:t1", status: .blocked, title: "Choose sample garden colors", agent: "Claude", revision: 97, firstSeenAt: Date().addingTimeInterval(-7_200), lastActivityAt: Date().addingTimeInterval(-22 * 60)),
                pane(id: "w1:p3", tabID: "w1:t2", status: .unknown, title: "Unit tests", agent: nil, revision: 52, firstSeenAt: Date().addingTimeInterval(-3 * 86_400), lastActivityAt: Date().addingTimeInterval(-2 * 86_400)),
            ],
            layouts: [layout(workspaceID: "w1", tabID: "w1:t1", paneIDs: ["w1:p1", "w1:p2"])]
        ),
        workspace(
            id: "w2",
            number: 2,
            label: "Reading Journal",
            path: "/tmp/herdr-demo/reading-journal",
            panes: [
                pane(id: "w2:p1", tabID: "w2:t1", status: .done, title: "Sample reading list export", agent: "Codex", revision: 311, firstSeenAt: Date(), lastActivityAt: Date()),
                pane(id: "w2:p2", tabID: "w2:t1", status: .working, title: "Validate the example book list", agent: "Claude", revision: 118, firstSeenAt: Date().addingTimeInterval(-5_400), lastActivityAt: Date(), workingSince: Date().addingTimeInterval(-35 * 60)),
            ],
            layouts: [layout(workspaceID: "w2", tabID: "w2:t1", paneIDs: ["w2:p1", "w2:p2"])]
        ),
        workspace(
            id: "w3",
            number: 3,
            label: "Weather Station",
            path: "/tmp/herdr-demo/weather-station",
            panes: [
                pane(id: "w3:p1", tabID: "w3:t1", status: .idle, title: "Describe the sample weather display", agent: "Codex", revision: 44, firstSeenAt: Date().addingTimeInterval(-10 * 86_400), lastActivityAt: Date().addingTimeInterval(-8 * 86_400)),
            ],
            layouts: [layout(workspaceID: "w3", tabID: "w3:t1", paneIDs: ["w3:p1"])]
        ),
    ]

    static let alerts: [HerdrAlert] = [
        HerdrAlert(
            id: "demo-blocked",
            workspaceID: "w1",
            paneID: "w1:p2",
            status: .blocked,
            title: "Choose the example garden theme",
            message: "The demo planning agent is waiting for a garden color choice.",
            createdAt: "2030-01-01T11:58:00Z",
            isRead: false
        ),
        HerdrAlert(
            id: "demo-done",
            workspaceID: "w2",
            paneID: "w2:p1",
            status: .done,
            title: "The sample book list is ready",
            message: "The demo reading list export contains three fictional book entries.",
            createdAt: "2030-01-01T11:55:00Z",
            isRead: false
        ),
    ]

    static let secondaryWorkspaces: [HerdrWorkspace] = [
        workspace(
            id: "w1",
            number: 1,
            label: "Art Notebook",
            path: "/tmp/herdr-demo/art-notebook",
            panes: [
                pane(id: "w1:p1", tabID: "w1:t1", status: .working, title: "Sketch a fictional postcard", agent: "Codex", revision: 28),
                pane(id: "w1:p2", tabID: "w1:t1", status: .idle, title: "Choose the sample postcard border", agent: "Claude", revision: 12),
            ],
            layouts: [layout(workspaceID: "w1", tabID: "w1:t1", paneIDs: ["w1:p1", "w1:p2"])]
        ),
        workspace(
            id: "w2",
            number: 2,
            label: "Weather Samples",
            path: "/tmp/herdr-demo/weather-samples",
            panes: [
                pane(id: "w2:p1", tabID: "w2:t1", status: .done, title: "Validate fictional weather readings", agent: "Codex", revision: 7),
            ],
            layouts: [layout(workspaceID: "w2", tabID: "w2:t1", paneIDs: ["w2:p1"])]
        ),
    ]

    static func terminalText(for paneID: String) -> String {
        switch paneID {
        case "demo1|w1:p2":
            """
            Fictional Garden Planner demo

            Choose a color for the example herb-garden tiles:
              1. Sage green
              2. Marigold yellow

            Waiting for a sample color choice.
            """
        case "demo1|w2:p1":
            """
            Fictional Reading Journal demo

            Exported three imaginary books:
              The Clockwork Orchard
              A Map of Paper Moons
              The Pocket Raincloud

            The sample export is ready to review.
            """
        case "demo2|w1:p2":
            """
            Fictional Art Notebook demo

            A sample postcard has a blue sky and two paper kites.
            Choose a dotted or striped border for the example.
            """
        case "demo2|w2:p1":
            """
            Fictional Weather Samples demo

            Example readings: sunny, breezy, light rain.
            All values are invented and describe no real location.
            """
        default:
            """
            Fictional Garden Planner demo

            Draft seed list: basil, thyme, marigold.
            The sample garden has three raised beds.
            The example layout is ready for a color preview.
            """
        }
    }

    static func gitStatus(for workspace: HerdrWorkspace) -> WorkspaceGitStatus {
        WorkspaceGitStatus(
            ok: true,
            workspaceID: workspace.id,
            branch: workspace.tokens["branch"] ?? "demo/garden-colors",
            cwd: workspace.displayPath,
            staged: [
                WorkspaceGitFile(status: "M", file: "Sources/Garden/GardenCanvas.swift"),
            ],
            unstaged: [
                WorkspaceGitFile(status: "M", file: "Sources/Garden/SeedPicker.swift"),
                WorkspaceGitFile(status: "M", file: "Sources/Reading/BookList.swift"),
            ],
            untracked: [
                "Sources/Garden/PlantCatalog.swift",
            ],
            commits: [
                WorkspaceGitCommit(hash: "111aaaa", message: "Add the fictional seed list"),
                WorkspaceGitCommit(hash: "222bbbb", message: "Arrange example garden beds"),
                WorkspaceGitCommit(hash: "333cccc", message: "Label sample plant colors"),
            ],
            error: nil
        )
    }

    static func gitDiff(file: String, section: GitFileSection) -> WorkspaceGitDiffResponse {
        WorkspaceGitDiffResponse(
            ok: true,
            file: file,
            section: section,
            diff: """
            diff --git a/\(file) b/\(file)
            index 17f4c31..92ab840 100644
            --- a/\(file)
            +++ b/\(file)
            @@ -42,6 +42,9 @@ struct GardenCanvas: View {
                 PlantTile(
                     plant: samplePlant,
            +        color: sampleColor,
            +        isSelected: $isSelected,
            +        select: selectSamplePlant,
                     label: sampleLabel
                 )
            """,
            error: nil
        )
    }

    static func skills(for workspace: HerdrWorkspace) -> SkillsResponse {
        let projectSkills = [
            ProjectSkill(
                name: "garden-layout",
                skillFilePath: "./.claude/skills/garden-layout/SKILL.md",
                scope: "project"
            ),
            ProjectSkill(
                name: "sample-review",
                skillFilePath: "./.claude/skills/sample-review/SKILL.md",
                scope: "project"
            ),
            ProjectSkill(
                name: "catalog-export",
                skillFilePath: "./.claude/skills/catalog-export/SKILL.md",
                scope: "project"
            ),
        ]
        let userSkills = [
            ProjectSkill(
                name: "demo-handoff",
                skillFilePath: "~/.codex/skills/demo-handoff/SKILL.md",
                scope: "user"
            ),
            ProjectSkill(
                name: "example-notes",
                skillFilePath: "~/.codex/skills/example-notes/SKILL.md",
                scope: "user"
            ),
        ]
        return SkillsResponse(
            ok: true,
            workspaceID: workspace.id,
            rootPath: workspace.displayPath,
            skillsDirectory: "\(workspace.displayPath)/.claude/skills",
            userSkillsDirectory: "~/.codex/skills",
            projectSkills: projectSkills,
            userSkills: userSkills,
            skills: projectSkills + userSkills,
            error: nil
        )
    }

    static func fileSearch(query: String, workspace: HerdrWorkspace) -> FileSearchResponse {
        FileSearchResponse(
            ok: true,
            workspaceID: workspace.id,
            rootPath: workspace.displayPath,
            query: query,
            files: [
                ProjectFileMatch(path: "Sources/Garden/GardenCanvas.swift"),
                ProjectFileMatch(path: "Sources/Garden/SeedPicker.swift"),
                ProjectFileMatch(path: "Tests/GardenCanvasTests.swift"),
            ].filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) },
            truncated: false,
            limit: 50,
            error: nil
        )
    }

    static let jiraTickets = JiraTicketsResponse(
        ok: true,
        project: "TASK",
        projects: ["TASK", "APP"],
        site: "example.atlassian.net",
        tickets: [
            JiraTicket(
                key: "TASK-101",
                projectKey: "TASK",
                title: "Choose a fictional garden layout",
                status: "In Progress",
                priority: "High",
                issueType: "Story",
                url: "https://example.atlassian.net/browse/TASK-101"
            ),
            JiraTicket(
                key: "APP-102",
                projectKey: "APP",
                title: "Label the sample weather chart",
                status: "Ready for QA",
                priority: "Medium",
                issueType: "Task",
                url: "https://example.atlassian.net/browse/APP-102"
            ),
        ],
        error: nil
    )

    private static func workspace(
        id: String,
        number: Int,
        label: String,
        path: String,
        panes: [HerdrPane],
        layouts: [HerdrLayout]
    ) -> HerdrWorkspace {
        let status = panes.min(by: { $0.agentStatus.attentionRank < $1.agentStatus.attentionRank })?.agentStatus ?? .unknown
        return HerdrWorkspace(
            workspaceID: id,
            number: number,
            label: label,
            focused: number == 1,
            paneCount: panes.count,
            tabCount: Set(panes.map(\.tabID)).count,
            activeTabID: panes.first?.tabID ?? "",
            agentStatus: status,
            tokens: ["branch": number == 1 ? "demo/garden-colors" : "main"],
            worktree: HerdrWorktree(
                repoKey: label.lowercased().replacing(" ", with: "-"),
                repoName: label,
                repoRoot: path,
                checkoutPath: path,
                isLinkedWorktree: number == 1
            ),
            tabs: Array(Set(panes.map(\.tabID))).sorted().enumerated().map { index, tabID in
                HerdrTab(
                    tabID: tabID,
                    workspaceID: id,
                    number: index + 1,
                    label: index == 0 ? "Agents" : "Tests",
                    focused: index == 0,
                    paneCount: panes.count(where: { $0.tabID == tabID }),
                    agentStatus: status
                )
            },
            panes: panes,
            layouts: layouts
        )
    }

    private static func pane(
        id: String,
        tabID: String,
        status: AgentStatus,
        title: String,
        agent: String?,
        revision: Int,
        firstSeenAt: Date? = nil,
        lastActivityAt: Date? = nil,
        workingSince: Date? = nil
    ) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: "term_\(id.replacing(":", with: "_"))",
            workspaceID: String(id.split(separator: ":").first ?? "w1"),
            tabID: tabID,
            focused: id == "w1:p1",
            agentStatus: status,
            revision: revision,
            cwd: "/tmp/herdr-demo",
            foregroundCWD: nil,
            label: nil,
            title: title,
            agent: agent?.lowercased(),
            displayAgent: agent,
            terminalTitle: title,
            terminalTitleStripped: title,
            firstSeenAt: firstSeenAt,
            lastActivityAt: lastActivityAt,
            workingSince: workingSince
        )
    }

    private static func layout(workspaceID: String, tabID: String, paneIDs: [String]) -> HerdrLayout {
        let width = 120
        let paneWidth = width / max(paneIDs.count, 1)
        return HerdrLayout(
            workspaceID: workspaceID,
            tabID: tabID,
            focusedPaneID: paneIDs.first,
            zoomed: false,
            area: HerdrLayoutRect(x: 0, y: 0, width: width, height: 36),
            panes: paneIDs.enumerated().map { index, id in
                HerdrLayoutPane(
                    paneID: id,
                    focused: index == 0,
                    rect: HerdrLayoutRect(x: index * paneWidth, y: 0, width: paneWidth, height: 36)
                )
            },
            splits: []
        )
    }
}
