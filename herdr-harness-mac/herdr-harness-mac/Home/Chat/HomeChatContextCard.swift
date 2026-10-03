import SwiftUI

struct HomeChatContextCard: View {
    let context: HomeChatContext
    var remove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label("From Home", systemImage: "house")
                    .font(.system(size: 11.5, weight: .medium))
                Text(context.observedAt, style: .time).font(.system(size: 11))
                Spacer(minLength: 4)
                if let remove {
                    Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.herdrPlain).accessibilityLabel("Remove Home context")
                }
            }
            .foregroundStyle(HomePalette.secondary)
            Text(context.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HomePalette.ink)
            Text(context.summary).font(.system(size: 12)).foregroundStyle(HomePalette.prose).lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-chat-context")
    }
}
