import SwiftUI

struct PiConnectionBanner: View {
    let connection: PiConversationConnection
    let message: String?
    let transport: PiStreamTransport

    var body: some View {
        if let content {
            HStack(spacing: 8) {
                if content.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(content.tint)
                } else {
                    Image(systemName: content.symbol)
                        .foregroundStyle(content.tint)
                }
                Text(message ?? content.text)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(content.tint.opacity(0.08))
            .herdrHairline(.bottom)
            .accessibilityElement(children: .combine)
        } else if connection == .connected, transport == .polling {
            HStack {
                Text("polling")
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true, weight: .medium)
                    .foregroundStyle(HerdrTheme.warning)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 20)
                    .background(HerdrTheme.warning.opacity(0.12), in: .rect(cornerRadius: 4))
                    .accessibilityIdentifier("pi-transport-polling")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var content: PiConnectionBannerContent? {
        if connection == .connected, let message, !message.isEmpty {
            return PiConnectionBannerContent(
                text: message,
                symbol: "exclamationmark.triangle.fill",
                tint: HerdrTheme.alert,
                showsProgress: false
            )
        }
        switch connection {
        case .loading:
            return PiConnectionBannerContent(text: "Loading native transcript…", symbol: "arrow.triangle.2.circlepath", tint: HerdrTheme.accent, showsProgress: true)
        case .connected:
            return nil
        case .bridgeOffline:
            return PiConnectionBannerContent(text: "Pi is offline. Transcript preserved.", symbol: "bolt.slash", tint: HerdrTheme.warning, showsProgress: false)
        case .reconnecting:
            return PiConnectionBannerContent(text: "Reconnecting to Pi…", symbol: "wifi.exclamationmark", tint: HerdrTheme.warning, showsProgress: true)
        case .unavailable:
            return PiConnectionBannerContent(text: "Native transcript unavailable", symbol: "terminal", tint: HerdrTheme.warning, showsProgress: false)
        }
    }
}
