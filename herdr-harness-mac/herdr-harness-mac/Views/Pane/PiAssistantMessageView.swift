import SwiftUI

struct PiAssistantMessageView: View {
    let block: PiAssistantBlock
    var skim: FirstMateSkim? = nil
    var isSkimmable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if block.status == .complete, isSkimmable || skim != nil {
                SkimPendingLabel(skim: skim)
                SkimmableReply(messageID: block.id, reply: block.text, skim: skim) {
                    PiMarkdownMessageView(source: block.text, isStreaming: false, id: block.id)
                }
            } else {
                PiMarkdownMessageView(source: block.text, isStreaming: block.status == .streaming, id: block.id)
            }

            if case let .failed(message) = block.status {
                Label(message ?? "Response stopped with an error", systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.alert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.status == .streaming ? "Pi is responding" : "Pi")
        .piCopyAffordance(
            block.text,
            label: "Copy response",
            identifier: "pi-assistant-copy-\(block.id)",
            inset: 0,
            offset: CGSize(width: 24, height: 0),
            isEnabled: block.status != .streaming
        )
    }
}
