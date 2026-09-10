import CoreGraphics

/// Pure panel-placement math. Offsets are deliberately monitor-relative so a
/// HUD keeps a sensible position when displays or resolutions change.
struct HerdrHudPlacement: Equatable, Sendable {
    var topRightOffset: CGSize

    static let defaultInset: CGFloat = 8
    static let collapsedSize = CGSize(width: 88, height: 72)
    /// Reserves the left satellite's half-width, mirroring the right edge.
    static let orbLeadingInset: CGFloat = 16
    static let orbControlScale: CGFloat = 0.8
    static let expandedSize = CGSize(width: 420, height: 580)
    static let shadowMargin: CGFloat = 40
    static let chipWidth: CGFloat = 200
    /// The chip's rendered height AND the height the panel frame reserves for
    /// it — `HerdrHudSessionChipsView` must read this, not `HerdrTheme`, or the
    /// two disagree and the collapsed panel mis-sizes. Deliberately larger than
    /// `HerdrTheme.minHitTarget`; a literal because this type is pure
    /// CoreGraphics math with no SwiftUI dependency.
    static let chipHeight: CGFloat = 74
    /// Reserve two title lines plus activity and status, retaining compact padding.
    /// Font reduction keeps the existing minimum control size.
    static func chipHeight(fontScale: Double) -> CGFloat {
        chipHeight + 58 * CGFloat(max(1, fontScale) - 1)
    }
    static let chipSpacing: CGFloat = 6
    /// The resting lane leaves room for one keyboard-focused title. Hovering
    /// the HUD grows it leftward to fit every visible title together.
    static let resultRailWidth: CGFloat = 224
    static let resultNodeSize: CGFloat = 30
    static let resultNodeSpacing: CGFloat = 5
    static let resultConnectorWidth: CGFloat = 13
    static let resultNodeExpandedWidth: CGFloat = 136
    static let maxVisibleResults = 3

    static func resultRailWidth(artifactCount: Int, expandsTitles: Bool) -> CGFloat {
        guard expandsTitles else { return resultRailWidth }
        let count = min(max(artifactCount, 0), maxVisibleResults)
        return max(
            resultRailWidth,
            CGFloat(count) * (resultNodeExpandedWidth + resultNodeSpacing) + resultConnectorWidth
        )
    }
    /// Default visible-agent preference; Show all has no projection cap.
    static let maxChips = 4

    static func overflowDiameter(count: Int, fontScale: Double = 1) -> CGFloat {
        max(28, CGFloat(String(max(0, count)).count + 1) * 7 + 12) * CGFloat(fontScale)
    }
    enum NotesLayout: Equatable, Sendable { case hidden, icon, compact(count: Int), rows(count: Int), card }
    static let notesToggleSize: CGFloat = 32
    static let notesGap: CGFloat = 10
    static let notesWidth: CGFloat = 236
    static let noteRowHeight: CGFloat = 40
    static let noteRowSpacing: CGFloat = 6
    static let noteCtaHeight: CGFloat = 30
    /// Tall enough for one line of the note's title — the collapsed stack names
    /// its notes rather than showing anonymous color bars.
    static let noteCompactBarHeight: CGFloat = 22
    static let noteCompactWidth: CGFloat = 158
    static let noteCompactBarSpacing: CGFloat = 4
    static let maxNoteRows = 6
    static let maxNoteRowsWhenExpanded = 3
    static let noteCardSize = CGSize(width: 320, height: 360)
    /// The reply composer is its own small surface beside the orb rather than a
    /// row inside the chat, so a spoken reply never looks like a HUD prompt.
    static let voiceReplyCardSize = CGSize(width: 300, height: 168)
    static let quickVoiceCardSize = CGSize(width: 336, height: 320)

    static func maxNoteRows(isExpanded: Bool) -> Int { isExpanded ? maxNoteRowsWhenExpanded : maxNoteRows }
    static func notesContentSize(_ layout: NotesLayout, isExpanded: Bool) -> CGSize {
        switch layout {
        case .hidden:
            return .zero
        case .icon:
            // Collapsed HUDs host this toggle on the orb, not in a separate row.
            return isExpanded ? CGSize(width: notesToggleSize, height: notesToggleSize) : .zero
        case let .compact(count):
            let k = max(count, 0) + 1 // Include the New note row.
            let rowsHeight = CGFloat(k) * (noteCompactBarHeight + noteCompactBarSpacing)
            return CGSize(width: noteCompactWidth, height: isExpanded ? notesToggleSize + rowsHeight : rowsHeight - noteCompactBarSpacing)
        case let .rows(count):
            let k = min(max(count, 0), maxNoteRows(isExpanded: isExpanded))
            return CGSize(width: notesWidth, height: noteCtaHeight + CGFloat(k) * (noteRowHeight + noteRowSpacing))
        case .card:
            return noteCardSize
        }
    }

    static func defaultOffset() -> CGSize {
        CGSize(width: defaultInset, height: defaultInset)
    }

    /// All compact notes get their natural height until the actual screen is
    /// full. Reserve the ordinary session rows; larger session lists can scroll.
    static func compactNotesViewportSize(
        count: Int,
        isExpanded: Bool,
        visibleFrameHeight: CGFloat,
        chipCount: Int,
        voiceReplySize: CGSize = .zero,
        quickVoiceSize: CGSize = .zero,
        fontScale: Double = 1
    ) -> CGSize {
        let natural = notesContentSize(.compact(count: count), isExpanded: isExpanded)
        guard natural.height > 0 else { return .zero }
        let sessionHeight = sessionStackContentHeight(chipCount: min(chipCount, maxChips), fontScale: fontScale)
        let mainHeight = isExpanded ? expandedSize.height
            : collapsedSize.height + (sessionHeight > 0 ? chipSpacing + sessionHeight : 0)
        let reserved = mainHeight + shadowMargin * 2 + notesGap
            + (voiceReplySize.height > 0 ? notesGap + voiceReplySize.height : 0)
            + (quickVoiceSize.height > 0 ? chipSpacing + quickVoiceSize.height : 0)
        let height = min(natural.height, max(0, visibleFrameHeight - reserved))
        return CGSize(width: natural.width + (height < natural.height ? 12 : 0), height: height)
    }

    static func sessionStackContentHeight(chipCount: Int, overflow: Int = 0, fontScale: Double = 1) -> CGFloat {
        let count = max(0, chipCount)
        let rowsHeight = CGFloat(count) * chipHeight(fontScale: fontScale) + CGFloat(max(0, count - 1)) * chipSpacing
        return rowsHeight + (overflow > 0 ? (count > 0 ? chipSpacing : 0) + overflowDiameter(count: overflow, fontScale: fontScale) : 0)
    }

    /// The panel and scroll view share this budget. Clamping the panel alone
    /// leaves fixed-height session rows drawn below its visible bounds.
    static func sessionStackHeight(
        chipCount: Int,
        overflow: Int = 0,
        visibleFrameHeight: CGFloat,
        notesSize: CGSize = .zero,
        voiceReplySize: CGSize = .zero,
        quickVoiceSize: CGSize = .zero,
        fontScale: Double = 1
    ) -> CGFloat {
        let reservedHeight = collapsedSize.height + shadowMargin * 2 + chipSpacing
            + (notesSize.height > 0 ? notesGap + notesSize.height : 0)
            + (voiceReplySize.height > 0 ? notesGap + voiceReplySize.height : 0)
            + (quickVoiceSize.height > 0 ? chipSpacing + quickVoiceSize.height : 0)
        return min(sessionStackContentHeight(chipCount: chipCount, overflow: overflow, fontScale: fontScale), max(0, visibleFrameHeight - reservedHeight))
    }

    static func collapsedContentSize(
        chipCount: Int,
        overflow: Int = 0,
        hasResultRail: Bool = false,
        resultArtifactCount: Int = 1,
        expandsResultTitles: Bool = false,
        sessionStackHeight: CGFloat? = nil,
        fontScale: Double = 1
    ) -> CGSize {
        let count = max(0, chipCount)
        let baseSize = if count > 0 || overflow > 0 {
            CGSize(
                width: max(collapsedSize.width, chipWidth),
                height: collapsedSize.height + chipSpacing
                    + min(Self.sessionStackContentHeight(chipCount: count, overflow: overflow, fontScale: fontScale), max(0, sessionStackHeight ?? .greatestFiniteMagnitude))
            )
        } else {
            collapsedSize
        }
        return CGSize(
            width: baseSize.width + (hasResultRail
                ? resultRailWidth(artifactCount: resultArtifactCount, expandsTitles: expandsResultTitles)
                : 0),
            height: baseSize.height
        )
    }

    static func frame(
        isExpanded: Bool,
        visibleFrame: CGRect,
        topRightOffset: CGSize,
        chipCount: Int = 0,
        overflow: Int = 0,
        hasResultRail: Bool = false,
        resultArtifactCount: Int = 1,
        expandsResultTitles: Bool = false,
        notesSize: CGSize = .zero,
        voiceReplySize: CGSize = .zero,
        quickVoiceSize: CGSize = .zero,
        fontScale: Double = 1
    ) -> CGRect {
        var contentSize = isExpanded
            ? expandedSize
            : collapsedContentSize(
                chipCount: chipCount,
                overflow: overflow,
                hasResultRail: hasResultRail,
                resultArtifactCount: resultArtifactCount,
                expandsResultTitles: expandsResultTitles,
                sessionStackHeight: sessionStackHeight(
                    chipCount: chipCount,
                    overflow: overflow,
                    visibleFrameHeight: visibleFrame.height,
                    notesSize: notesSize,
                    voiceReplySize: voiceReplySize,
                    quickVoiceSize: quickVoiceSize,
                    fontScale: fontScale
                ),
                fontScale: fontScale
            )
        if quickVoiceSize.height > 0 {
            contentSize.width = max(contentSize.width, quickVoiceSize.width)
            contentSize.height += chipSpacing + quickVoiceSize.height
        }
        if voiceReplySize.height > 0 {
            contentSize.width = max(contentSize.width, voiceReplySize.width)
            contentSize.height += notesGap + voiceReplySize.height
        }
        if notesSize.height > 0 {
            let availableContentHeight = max(0, visibleFrame.height - shadowMargin * 2)
            let excess = max(0, contentSize.height + notesGap + notesSize.height - availableContentHeight)
            let shrunkNotesHeight = max(noteCtaHeight, notesSize.height - excess)
            contentSize.width = max(contentSize.width, notesSize.width)
            contentSize.height += notesGap + shrunkNotesHeight
        }
        let preferredSize = CGSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )
        // A visible frame smaller than the HUD is unusual, but this keeps the
        // contract true even on extremely constrained displays.
        let size = CGSize(
            width: min(preferredSize.width, visibleFrame.width),
            height: min(preferredSize.height, visibleFrame.height)
        )
        let desiredX = visibleFrame.maxX - topRightOffset.width - size.width
        let desiredY = visibleFrame.maxY - topRightOffset.height - size.height
        let x = min(max(desiredX, visibleFrame.minX - shadowMargin), visibleFrame.maxX - size.width + shadowMargin)
        let y = min(max(desiredY, visibleFrame.minY - shadowMargin), visibleFrame.maxY - size.height + shadowMargin)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func offset(forFrame frame: CGRect, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: visibleFrame.maxX - frame.maxX,
            height: visibleFrame.maxY - frame.maxY
        )
    }

    static func reclamp(
        topRightOffset: CGSize,
        isExpanded: Bool,
        visibleFrame: CGRect
    ) -> CGSize {
        let clampedFrame = frame(
            isExpanded: isExpanded,
            visibleFrame: visibleFrame,
            topRightOffset: topRightOffset
        )
        return offset(forFrame: clampedFrame, visibleFrame: visibleFrame)
    }
}
