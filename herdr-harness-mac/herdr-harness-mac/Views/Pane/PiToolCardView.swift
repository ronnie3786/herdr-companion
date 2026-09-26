import SwiftUI

struct PiToolCardView: View {
    let tool: PiToolInvocation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.herdrFontScale) private var fontScale
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        let presentation = PiToolPresentation(tool: tool)
        // MonoCode's unboxed tool row: failure reads through the title color
        // and the "Failed" status, not a box.
        PiDisclosureCard(isExpanded: $isExpanded, chevronColor: HerdrTheme.iconTint) {
            detail
        } label: {
            label(presentation)
        }
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: tool.status)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("pi-tool-\(tool.callID)")
    }

    private func label(_ presentation: PiToolPresentation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: presentation.symbol)
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .frame(width: 16)
                .foregroundStyle(isFailed ? HerdrTheme.alert : HerdrTheme.iconTint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .herdrFont(size: HerdrTheme.TextSize.reading)
                    .foregroundStyle(isFailed ? HerdrTheme.alert : HerdrTheme.tertiaryText)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .herdrFont(size: HerdrTheme.TextSize.body, monospaced: true)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .lineLimit(presentation.command == nil ? 1 : 3)
                }
            }

            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                statusLabel
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                    .id(statusMotionKey)
                    .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                if let elapsedDuration {
                    Text(elapsedDuration)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(statusAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = PiToolPresentation(tool: tool).command {
                toolSection("Command", text: command)
            }
            if let argumentsDisplayString = tool.argumentsDisplayString {
                toolSection("Input", text: argumentsDisplayString)
                    .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
            }
            if let resultDisplayString = tool.resultDisplayString {
                toolSection(tool.status == .failed ? "Error" : "Result", text: resultDisplayString)
                    .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
            }
            if tool.arguments == nil, tool.result == nil {
                Text("Waiting for tool details…")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .transition(.opacity)
            }
        }
        .padding(.top, 4)
        .padding(.leading, 22)
        .animation(
            PiChatMotion.structuralAnimation(reduceMotion: reduceMotion),
            value: detailStructure
        )
    }

    private func toolSection(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HerdrMicroLabel(text: label)
            Text(text)
                .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                .lineSpacing(HerdrProse.lineSpacing(size: HerdrTheme.TextSize.small, lineHeight: 20, scale: fontScale, monospaced: true))
                .foregroundStyle(label == "Error" ? HerdrTheme.alert : HerdrTheme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch tool.status {
        case .waiting:
            Text("Queued")
                .foregroundStyle(HerdrTheme.tertiaryText)
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Running")
            }
            .foregroundStyle(HerdrTheme.working)
        case .succeeded:
            Label("Done", systemImage: "checkmark")
                .foregroundStyle(HerdrTheme.success)
        case .failed:
            Label("Failed", systemImage: "exclamationmark")
                .foregroundStyle(HerdrTheme.alert)
        }
    }

    private var isFailed: Bool { tool.status == .failed }

    private var elapsedDuration: String? {
        guard let startedAt = tool.startedAt else { return nil }
        let end = tool.finishedAt ?? .now
        let seconds = max(0, end.timeIntervalSince(startedAt))
        return seconds < 10 ? String(format: "%.1fs", seconds) : "\(Int(seconds))s"
    }

    private var statusAccessibilityLabel: String {
        let status: String
        switch tool.status {
        case .waiting: status = "Queued"
        case .running: status = "Running"
        case .succeeded: status = "Completed"
        case .failed: status = "Failed"
        }
        if let elapsedDuration { return "\(status), \(elapsedDuration)" }
        return status
    }

    private var statusMotionKey: Int {
        switch tool.status {
        case .waiting: 0
        case .running: 1
        case .succeeded: 2
        case .failed: 3
        }
    }

    private var detailStructure: Int {
        (tool.arguments == nil ? 0 : 1) | (tool.result == nil ? 0 : 2)
    }
}
