import SwiftUI

/// A segment in the bounded, eagerly laid-out Pi chat timeline. Each segment
/// retains its identity so streamed tokens invalidate only the owning row.
struct PiTimelineRow: Identifiable, Equatable {
    enum Content: Equatable {
        case user(PiUserMessage)
        case output(PiConversationItem)
        case working(PiWorkingGroup)
        case artifacts([AgentResultArtifact])
        /// The "Pi is starting…" placeholder for an active turn with no items.
        case starting
    }

    let id: String
    let turnID: String
    let content: Content
    /// First row of a turn that is not the first turn in the timeline: gets
    /// `HerdrProse.turnSpacing` above it instead of the in-turn item spacing.
    let startsTurn: Bool
    /// The very first row: no spacing above it at all.
    let isFirstInTimeline: Bool

    var topSpacing: CGFloat {
        if isFirstInTimeline { return 0 }
        return startsTurn ? HerdrProse.turnSpacing : PiTimelineMetrics.itemSpacing
    }

    func asFirstInTimeline() -> PiTimelineRow {
        PiTimelineRow(
            id: id,
            turnID: turnID,
            content: content,
            startsTurn: startsTurn,
            isFirstInTimeline: true
        )
    }

    /// Flattens turns into rows, preserving the reducer's item order. Segments
    /// come from `PiTurnSegmentation` so working groups keep the identity they
    /// had as turn children (expansion state survives the flattening).
    static func rows(
        for turns: [PiConversationTurn],
        artifactsByTurnID: [String: [AgentResultArtifact]] = [:]
    ) -> [PiTimelineRow] {
        var rows: [PiTimelineRow] = []
        rows.reserveCapacity(turns.reduce(0) { $0 + $1.items.count + 2 })
        var isFirstTurn = true

        for turn in turns {
            var contents: [(id: String, content: Content)] = []
            if let user = turn.user {
                contents.append(("\(turn.id)|user", .user(user)))
            }
            for segment in PiTurnSegmentation.segments(for: turn.items) {
                switch segment {
                case let .output(item):
                    contents.append(("\(turn.id)|\(segment.id)", .output(item)))
                case let .working(group):
                    contents.append(("\(turn.id)|\(segment.id)", .working(group)))
                }
            }
            if turn.isActive, turn.items.isEmpty {
                contents.append(("\(turn.id)|starting", .starting))
            }
            if let artifacts = artifactsByTurnID[turn.id], !artifacts.isEmpty {
                contents.append(("\(turn.id)|attachments", .artifacts(artifacts)))
            }
            guard !contents.isEmpty else { continue }

            for (index, entry) in contents.enumerated() {
                rows.append(
                    PiTimelineRow(
                        id: entry.id,
                        turnID: turn.id,
                        content: entry.content,
                        startsTurn: index == 0,
                        isFirstInTimeline: isFirstTurn && index == 0
                    )
                )
            }
            isFirstTurn = false
        }
        return rows
    }
}

/// The slice of the timeline that is actually mounted. The transcript stack
/// is eager (see `PiChatTimelineView`), so a session with thousands of rows
/// must not mount them all up front: only the newest `limit` rows are, and the
/// user can ask for the rest. The first mounted row is re-stamped as the
/// first in the timeline so it carries no dangling top spacing.
struct PiTimelineWindow: Equatable {
    /// Rows mounted on the first frame of a transcript.
    static let initialLimit = 36
    /// Rows mounted once the first frame is up.
    static let defaultLimit = 160

    let rows: [PiTimelineRow]
    let hiddenCount: Int

    init(rows: [PiTimelineRow], showsEarlierRows: Bool, limit: Int = PiTimelineWindow.defaultLimit) {
        let hidden = showsEarlierRows ? 0 : max(0, rows.count - max(1, limit))
        guard hidden > 0 else {
            self.rows = rows
            self.hiddenCount = 0
            return
        }
        var visible = Array(rows[hidden...])
        visible[0] = visible[0].asFirstInTimeline()
        self.rows = visible
        self.hiddenCount = hidden
    }
}

enum PiTimelineMetrics {
    static let itemSpacing: CGFloat = 13
}

/// A single timeline row. Content uses the full reading width; spacing alone
/// separates turns without a decorative rail or a reserved leading gutter.
///
/// `Equatable` on the row model is the whole point: SwiftUI skips the body
/// (and therefore the layout) of every row whose content did not change.
struct PiTimelineRowView: View, Equatable {
    let row: PiTimelineRow
    var artifactModel: HerdrAppModel? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, row.topSpacing)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case let .user(message):
            PiUserMessageView(message: message)
        case let .output(item):
            PiConversationItemView(item: item)
        case let .working(group):
            PiWorkingGroupView(group: group)
        case let .artifacts(artifacts):
            if let artifactModel {
                PiResponseArtifactsView(model: artifactModel, artifacts: artifacts)
            }
        case .starting:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(HerdrTheme.mauve)
                Text("Pi is starting…")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
    }

    private var accessibilityIdentifier: String {
        switch row.content {
        case .starting: "pi-turn-starting-\(row.turnID)"
        case .user: "pi-turn-\(row.turnID)"
        case .output, .working, .artifacts: "pi-row-\(row.id)"
        }
    }
}
