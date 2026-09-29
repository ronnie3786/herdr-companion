import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Mounted Mac chat sidebar rows", .serialized)
@MainActor
struct SidebarChatRowRenderTests {
    private let context = SidebarChatRow.LocationContext(
        machine: "Lab · Lab", workspace: "Synthetic Project", tab: "Planning"
    )

    @Test("Actual title and footer geometry stays bounded across sidebar widths and text scales",
          arguments: [CGFloat(240), 260, 480], [HerdrFontScale.medium, .xxxLarge])
    func mountedLayout(width: CGFloat, scale: HerdrFontScale) async throws {
        let short = await measure("Short", width: width, scale: scale)
        let wrapping = await measure("Review a synthetic planning document and summarize the next steps for every invented sample session in this workspace", width: width, scale: scale)
        let overlong = await measure(String(repeating: "A much longer sample conversation title ", count: 10), width: width, scale: scale)
        let title = try #require(short.rects[.title])
        let wrappedTitle = try #require(wrapping.rects[.title])
        let longTitle = try #require(overlong.rects[.title])
        let footer = try #require(overlong.rects[.footer])
        let star = try #require(overlong.rects[.star])
        #expect(wrappedTitle.height > title.height + 1, "Title should grow naturally to two lines")
        #expect(longTitle.height <= wrappedTitle.height + 1, "A longer title must stop after line two")
        #expect(overlong.height > short.height)
        #expect(overlong.fittedWidth <= width + 1)
        #expect(longTitle.maxX <= star.minX + 1)
        #expect(footer.minY >= longTitle.maxY - 1)
        #expect(star.maxX <= width - 4)
        #expect(footer.maxY <= overlong.height + 2)
    }

    @Test("Narrow rails move long location above the final status line")
    func adaptiveFooter() async throws {
        let location = SidebarChatRow.LocationContext(
            machine: "Synthetic Machine", workspace: "Sample Project Name", tab: "Planning"
        )
        let narrow = await measure("Short", width: 240, scale: .medium, context: location)
        let wide = await measure("Short", width: 480, scale: .medium, context: location)
        let narrowFooter = try #require(narrow.rects[.footer])
        let wideFooter = try #require(wide.rects[.footer])
        let narrowTitle = try #require(narrow.rects[.title])
        #expect(narrowFooter.height > wideFooter.height + 5)
        #expect(narrowFooter.minY >= narrowTitle.maxY)
        #expect(wideFooter.maxX <= 480)
    }

    @Test("Synthetic selected, unread, shell, and missing-date rows render without indicator headers")
    func renderStates() async throws {
        let rows = VStack(spacing: 0) {
            row("π - Sample Pi title", status: .working, selected: true, unread: true,
                tabColor: .lavender)
            row("Shell sample", status: .unknown)
            row("Selected idle example", status: .idle, selected: true)
            row("Reminder example", status: .idle, unread: true, manuallyUnread: true)
            row("Orphaned example", status: .idle, parentContext: "Parent session unavailable")
            row("A child in another workspace with a long sample title", status: .blocked,
                crossWorkspace: true)
        }
        .frame(width: 260)
        .background(HerdrTheme.railBackground)
        let image = try await HerdrRenderHarness.render(
            "sidebar-chat-rows-synthetic.png", size: CGSize(width: 260, height: 450)
        ) { rows }
        image.expectSubstantial()
    }

    private func row(_ title: String, status: AgentStatus = .idle,
                     selected: Bool = false, unread: Bool = false,
                     context suppliedContext: SidebarChatRow.LocationContext? = nil,
                     tabColor: ChatTabColor? = nil, parentContext: String? = nil,
                     crossWorkspace: Bool = false, manuallyUnread: Bool = false) -> some View {
        let chat = pane(title, status: status)
        return SidebarChatRow(
            pane: chat, locationContext: suppliedContext ?? context,
            tabColor: tabColor, isSelected: selected, isUnread: unread,
            isManuallyUnread: manuallyUnread, hierarchy: crossWorkspace ? .init(pane: chat, depth: 1, childCount: 0,
                                               isExpanded: false, workspaceLabel: "Other Sample Project") : nil,
            parentContext: parentContext, since: nil, action: {}, toggleStar: {}
        )
    }

    private func pane(_ title: String, status: AgentStatus) -> HerdrPane {
        HerdrPane(
            paneID: "w1:p1", terminalID: "t1", workspaceID: "w1", tabID: "w1:t1",
            focused: false, agentStatus: status, revision: 0,
            cwd: nil, foregroundCWD: nil, label: title, title: nil,
            agent: status == .unknown ? nil : "pi", displayAgent: nil,
            terminalTitle: nil, terminalTitleStripped: nil
        ).stamped(machineID: "machine-1")
    }

    private func measure(_ title: String, width: CGFloat, scale: HerdrFontScale,
                         context: SidebarChatRow.LocationContext? = nil) async -> (
        height: CGFloat, fittedWidth: CGFloat, rects: [SidebarChatLayoutPart: CGRect]
    ) {
        var rects: [SidebarChatLayoutPart: CGRect] = [:]
        let hosting = NSHostingView(rootView:
            row(title, context: context)
                .environment(\.herdrFontScale, scale)
                .frame(width: width)
                .backgroundPreferenceValue(SidebarChatLayoutKey.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.onAppear {
                            rects = anchors.mapValues { proxy[$0] }
                        }
                    }
                }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 260)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        return (hosting.fittingSize.height, hosting.fittingSize.width, rects)
    }
}
