import SwiftUI

struct HerdrHudTranscriptRowView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession
    let exchange: HerdrHudExchange
    let showsAudioControls: Bool
    let allowsPromote: Bool
    let openPaneInMainWindow: (String) -> Void
    let collapse: () -> Void
    var allowsQuote = false
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            promptBubble
            if !exchange.steps.isEmpty {
                HerdrHudWorkingGroupView(exchange: exchange)
            }
            answer
                .environment(\.saveChatQuote, quoteAction)
            HerdrHudInlineResultArtifactsView(model: model, exchange: exchange)
            if isCompletedResponse {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("hud-transcript-row-\(exchange.id)")
        .environment(\.chatQuoteSource, "HUD exchange \(exchange.id)")
    }

    private var quoteAction: (@MainActor (ChatQuote) async throws -> Void)? {
        guard allowsQuote else { return nil }
        return { quote in
            guard ChatQuoteEligibility.hudExchangeIDs(in: session.exchanges).contains(exchange.id) else {
                throw NSError(domain: "ChatQuote", code: 1, userInfo: [NSLocalizedDescriptionKey: "This response is no longer among the last three agent messages. Select a more recent response."])
            }
            session.addQuote(quote)
        }
    }

    private var promptBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ChatSelectableText(text: AttributedString(exchange.prompt), font: HerdrProse.font(.body, scale: fontScale))
                .foregroundStyle(HerdrTheme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
            if !exchange.localAttachments.isEmpty {
                ForEach(exchange.localAttachments) { attachment in
                    HerdrHudSentAttachmentView(attachment: attachment)
                }
            } else if !exchange.attachmentFilenames.isEmpty {
                Label(exchange.attachmentFilenames.joined(separator: ", "), systemImage: "paperclip")
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(2)
            }
            Text(exchange.createdAt, format: .dateTime.hour().minute())
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var answer: some View {
        if hasError {
            VStack(alignment: .leading, spacing: 7) {
                Text(exchange.error ?? exchange.status.label)
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.alert)
                Button("Retry", systemImage: "arrow.counterclockwise", action: retry)
                    .buttonStyle(.bordered)
                    .tint(HerdrTheme.accent)
                    .controlSize(.small)
                    .disabled(session.isRunning)
                    .accessibilityIdentifier("hud-retry-\(exchange.id)")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        } else if let response = exchange.response, !response.isEmpty {
            PiMarkdownMessageView(source: response, isStreaming: false, id: "hud-\(exchange.id)")
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        } else {
            Text("No response")
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.muted)
                .italic()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(exchange.modelLabel)
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
            if let costUSD = exchange.costUSD {
                Text("$\(costUSD.formatted(.number.precision(.fractionLength(4))))")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer()
            if showsAudioControls, let response = exchange.response {
                ResponseAudioControlsView(
                    player: session.responseAudioPlayer,
                    showsTitles: false,
                    activate: { action in
                        session.activateResponseAudio(
                            action,
                            text: response,
                            exchangeID: exchange.id,
                            model: model
                        )
                    }
                )
            }
            promotionControl
        }
    }

    @ViewBuilder
    private var promotionControl: some View {
        if let paneID = exchange.promotedPaneID {
            Button("Open terminal session", systemImage: "terminal") {
                collapse()
                openPaneInMainWindow(MachineScopedID.compose(machineID: exchange.machineID, rawID: paneID))
            }
            .controlSize(.small)
            .disabled(model.pane(id: MachineScopedID.compose(machineID: exchange.machineID, rawID: paneID)) == nil)
            .help("Return to the promoted Pi session; its terminal pane must still exist")
        } else if allowsPromote {
            Button(action: promote) {
                HStack(spacing: 5) {
                    if isPromoting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Continue in agent")
                        .herdrFont(.caption, weight: .bold)
                }
            }
            .herdrProminentButton()
            .controlSize(.small)
            .disabled(isPromoting || session.isRunning || session.isLoadingHistory)
            .help("Promote the full saved conversation into a terminal workspace")
            .accessibilityIdentifier("hud-promote-\(exchange.id)")
        }
    }

    private var hasError: Bool {
        exchange.status == .failed || exchange.status == .cancelled || exchange.error != nil
    }

    private var isCompletedResponse: Bool {
        exchange.response?.isEmpty == false
            && (exchange.status == .completed || exchange.status == .promoted)
    }

    private var isPromoting: Bool {
        session.promotingExchangeIDs.contains(exchange.id)
    }

    private func retry() {
        Task { await session.retry(exchange, model: model) }
    }

    private func promote() {
        Task {
            guard let pane = await session.promote(exchange: exchange, model: model) else { return }
            collapse()
            openPaneInMainWindow(pane.id)
        }
    }
}
