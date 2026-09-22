import SwiftUI

/// Lays out an intrinsic leading Model/Thinking group and optional trailing
/// response-audio controls against the width the composer actually proposes.
/// Long model names receive only the remaining budget and truncate in place.
struct PiComposerOptionsLayout: Layout {
    static let modelMinimumWidth: CGFloat = 44
    static let thinkingMinimumWidth: CGFloat = 44
    static let spacing: CGFloat = 4

    let isAccessibilitySize: Bool

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        plan(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let plan = plan(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for index in subviews.indices {
            guard let frame = plan.frames[index] else { continue }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func plan(proposal: ProposedViewSize, subviews: Subviews) -> Plan {
        let naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let modelVisible = isVisible(0, sizes: naturalSizes)
        let thinkingVisible = isVisible(1, sizes: naturalSizes)
        let audioVisible = isVisible(2, sizes: naturalSizes)
        let modelNaturalWidth = modelVisible
            ? max(Self.modelMinimumWidth, naturalSizes[0].width)
            : 0
        let thinkingWidth = thinkingVisible
            ? max(Self.thinkingMinimumWidth, naturalSizes[1].width)
            : 0
        let controlsNaturalWidth = modelNaturalWidth
            + thinkingWidth
            + (modelVisible && thinkingVisible ? Self.spacing : 0)
        let audioWidth = audioVisible ? naturalSizes[2].width : 0
        let audioGap = (modelVisible || thinkingVisible) && audioVisible ? Self.spacing : 0
        let fallbackWidth = controlsNaturalWidth + audioGap + audioWidth
        let width = max(0, proposal.width ?? fallbackWidth)
        let controlsMinimumWidth = (modelVisible ? Self.modelMinimumWidth : 0)
            + thinkingWidth
            + (modelVisible && thinkingVisible ? Self.spacing : 0)
        let inlineMinimumWidth = controlsMinimumWidth + audioGap + audioWidth

        if isAccessibilitySize || controlsMinimumWidth > width {
            return stackedPlan(width: width, subviews: subviews, naturalSizes: naturalSizes)
        }
        if audioVisible && inlineMinimumWidth > width {
            return audioBelowPlan(
                width: width,
                subviews: subviews,
                naturalSizes: naturalSizes,
                thinkingWidth: thinkingWidth
            )
        }
        return inlinePlan(
            width: width,
            subviews: subviews,
            naturalSizes: naturalSizes,
            thinkingWidth: thinkingWidth
        )
    }

    private func inlinePlan(
        width: CGFloat,
        subviews: Subviews,
        naturalSizes: [CGSize],
        thinkingWidth: CGFloat
    ) -> Plan {
        let modelVisible = isVisible(0, sizes: naturalSizes)
        let thinkingVisible = isVisible(1, sizes: naturalSizes)
        let audioVisible = isVisible(2, sizes: naturalSizes)
        let audioWidth = audioVisible ? naturalSizes[2].width : 0
        let controlsWidth = max(
            0,
            width
                - audioWidth
                - ((modelVisible || thinkingVisible) && audioVisible ? Self.spacing : 0)
        )
        var frames = emptyFrames(count: subviews.count)
        let controlHeight = placeControlRow(
            width: controlsWidth,
            y: 0,
            thinkingWidth: thinkingWidth,
            subviews: subviews,
            naturalSizes: naturalSizes,
            frames: &frames
        )
        if audioVisible {
            frames[2] = CGRect(
                x: width - audioWidth,
                y: 0,
                width: audioWidth,
                height: naturalSizes[2].height
            )
        }
        let height = max(controlHeight, audioVisible ? naturalSizes[2].height : 0)
        return Plan(
            size: CGSize(width: width, height: height),
            frames: verticallyCentered(frames, height: height)
        )
    }

    private func audioBelowPlan(
        width: CGFloat,
        subviews: Subviews,
        naturalSizes: [CGSize],
        thinkingWidth: CGFloat
    ) -> Plan {
        var frames = emptyFrames(count: subviews.count)
        let controlsHeight = placeControlRow(
            width: width,
            y: 0,
            thinkingWidth: thinkingWidth,
            subviews: subviews,
            naturalSizes: naturalSizes,
            frames: &frames
        )
        let audioSize = naturalSizes[2]
        frames[2] = CGRect(
            x: max(0, width - audioSize.width),
            y: controlsHeight + Self.spacing,
            width: min(width, audioSize.width),
            height: audioSize.height
        )
        return Plan(
            size: CGSize(width: width, height: controlsHeight + Self.spacing + audioSize.height),
            frames: frames
        )
    }

    private func stackedPlan(
        width: CGFloat,
        subviews: Subviews,
        naturalSizes: [CGSize]
    ) -> Plan {
        var frames = emptyFrames(count: subviews.count)
        var y: CGFloat = 0
        var placedCount = 0

        for index in subviews.indices where isVisible(index, sizes: naturalSizes) {
            if placedCount > 0 { y += Self.spacing }
            let isAudio = index == 2
            let itemWidth = isAudio ? min(width, naturalSizes[index].width) : width
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: itemWidth, height: nil)
            )
            frames[index] = CGRect(
                x: isAudio ? max(0, width - itemWidth) : 0,
                y: y,
                width: itemWidth,
                height: size.height
            )
            y += size.height
            placedCount += 1
        }
        return Plan(size: CGSize(width: width, height: y), frames: frames)
    }

    @discardableResult
    private func placeControlRow(
        width: CGFloat,
        y: CGFloat,
        thinkingWidth: CGFloat,
        subviews: Subviews,
        naturalSizes: [CGSize],
        frames: inout [CGRect?]
    ) -> CGFloat {
        let modelVisible = isVisible(0, sizes: naturalSizes)
        let thinkingVisible = isVisible(1, sizes: naturalSizes)
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0

        if modelVisible {
            let reservedThinking = thinkingVisible ? thinkingWidth + Self.spacing : 0
            let availableWidth = max(Self.modelMinimumWidth, width - reservedThinking)
            let modelWidthBudget = min(
                availableWidth,
                max(Self.modelMinimumWidth, naturalSizes[0].width)
            )
            let size = subviews[0].sizeThatFits(
                ProposedViewSize(width: modelWidthBudget, height: nil)
            )
            let modelWidth = min(
                modelWidthBudget,
                max(Self.modelMinimumWidth, size.width)
            )
            frames[0] = CGRect(x: x, y: y, width: modelWidth, height: size.height)
            x += modelWidth + (thinkingVisible ? Self.spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        if thinkingVisible {
            let availableWidth = max(0, width - x)
            let itemWidth = min(availableWidth, thinkingWidth)
            let size = subviews[1].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            frames[1] = CGRect(x: x, y: y, width: itemWidth, height: size.height)
            rowHeight = max(rowHeight, size.height)
        }
        return rowHeight
    }

    private func isVisible(_ index: Int, sizes: [CGSize]) -> Bool {
        sizes.indices.contains(index) && sizes[index].width > 0 && sizes[index].height > 0
    }

    private func emptyFrames(count: Int) -> [CGRect?] {
        Array(repeating: nil, count: count)
    }

    private func verticallyCentered(_ frames: [CGRect?], height: CGFloat) -> [CGRect?] {
        frames.map { frame in
            guard var frame else { return nil }
            frame.origin.y += max(0, (height - frame.height) / 2)
            return frame
        }
    }

    private struct Plan {
        let size: CGSize
        let frames: [CGRect?]
    }
}
