import SwiftUI

struct PiAssistantMessageView: View {
    let block: PiAssistantBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PiMarkdownMessageView(source: block.text, isStreaming: block.status == .streaming, id: block.id)

            if case let .failed(message) = block.status {
                Label(message ?? "Response stopped with an error", systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(block.status == .streaming ? "Pi is responding" : "Pi: \(block.text)")
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
