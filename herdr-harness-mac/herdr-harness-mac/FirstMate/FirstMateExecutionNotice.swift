import SwiftUI

struct FirstMateExecutionNotice: View {
    let text: String
    var lastSuccessAt: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle")
                .herdrFont(.caption)
            if let lastSuccessAt {
                Text("Last successful monitoring pass: \(lastSuccessAt)")
                    .herdrFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .foregroundStyle(.orange)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.05))
        .accessibilityIdentifier("first-mate-execution-notice")
    }
}
