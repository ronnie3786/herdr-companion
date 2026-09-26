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
    var isActiveExchange = false
    @AppStorage(ChatActivityPreferences.groupAllClankingActivityKey)
    private var groupAllClankingActivity = ChatActivityPreferences.defaultGroupAllClankingActivity
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptBubble
            if showsWorkingGroup {
                HerdrHudWorkingGroupView(
                    exchange: exchange,
                    stepsOverride: activitySteps,
                    interimResponse: groupAllClankingActivity ? activityResponse : nil,
                    isLive: isActiveExchange
                )
            }
            if HerdrHudTranscriptPresentation.showsResponse(
                status: exchange.status,
                groupAllClankingActivity: groupAllClankingActivity
            ) {
                answer
                    .environment(\.saveChatQuote, quoteAction)
                    .paneResponseLinks(model: model, sourceMachineID: exchange.machineID) { paneID in
                        collapse()
                        openPaneInMainWindow(paneID)
                    }
            }
            HerdrHudInlineResultArtifactsView(model: model, exchange: exchange)
                .padding(.top, 8)
            if isCompletedResponse {
                footer
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("hud-transcript-row-\(exchange.id)")
        .environment(\.chatQuoteSource, "HUD exchange \(exchange.id)")
    }

    private var activitySteps: [HerdrHudStep] {
        if isActiveExchange, !session.liveSteps.isEmpty { return session.liveSteps }
        return exchange.steps
    }

    private var activityResponse: String? {
        guard isActiveExchange else { return nil }
        return session.liveResponse ?? exchange.response
    }

    private var showsWorkingGroup: Bool {
        !activitySteps.isEmpty || (groupAllClankingActivity && isActiveExchange)
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
        VStack(alignment: .trailing, spacing: 5) {
            // Hugs its text: a pill while it fits one line, 12pt corners beyond.
            Text(exchange.prompt)
                .font(HerdrProse.font(.userBubble, scale: fontScale))
                .lineSpacing(HerdrProse.lineSpacing(.userBubble, scale: fontScale))
                .foregroundStyle(HerdrTheme.primaryText)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    HerdrTheme.selectedFill,
                    in: HerdrBubbleShape(singleLineHeight: (HerdrProse.Role.userBubble.lineHeight + 16) * fontScale.rawValue)
                )
                .frame(maxWidth: 360 * fontScale.rawValue, alignment: .trailing)
            if !exchange.localAttachments.isEmpty {
                ForEach(exchange.localAttachments) { attachment in
                    HerdrHudSentAttachmentView(attachment: attachment)
                }
            } else if !exchange.attachmentFilenames.isEmpty {
                Label(exchange.attachmentFilenames.joined(separator: ", "), systemImage: "paperclip")
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(2)
            }
            Text(exchange.createdAt, format: .dateTime.hour().minute())
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .monospacedDigit()
                .foregroundStyle(HerdrTheme.tertiaryText)
                .padding(.trailing, 2)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var answer: some View {
        if hasError {
            VStack(alignment: .leading, spacing: 7) {
                Text(exchange.error ?? exchange.status.label)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .foregroundStyle(HerdrTheme.alert)
                Button("Retry", systemImage: "arrow.counterclockwise", action: retry)
                    .buttonStyle(HerdrRowButtonStyle())
                    .disabled(session.isEnding || session.hasEnded || session.isRunning || session.isLoadingHistory || session.needsHistoryRefresh
                              || !session.promotingExchangeIDs.isEmpty
                              || session.exchanges.contains(where: { $0.promotedPaneID != nil }))
                    .accessibilityIdentifier("hud-retry-\(exchange.id)")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrCard(radius: HerdrTheme.Radius.composer)
            .padding(.top, 12)
        } else if let response = exchange.response, !response.isEmpty {
            // Bubble-less prose, as in the main chat.
            PiMarkdownMessageView(source: response, isStreaming: false, id: "hud-\(exchange.id)")
                .textSelection(.enabled)
                .padding(.horizontal, 4)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if exchange.status.isTerminal {
            Text("No response")
                .herdrFont(size: HerdrTheme.TextSize.body)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .italic()
                .padding(.horizontal, 4)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(exchange.modelLabel)
                .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.tertiaryText)
            if let costUSD = exchange.costUSD {
                Text("$\(costUSD.formatted(.number.precision(.fractionLength(4))))")
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.tertiaryText)
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
            .buttonStyle(HerdrRowButtonStyle())
            .disabled(model.pane(id: MachineScopedID.compose(machineID: exchange.machineID, rawID: paneID)) == nil)
            .help("Return to the promoted Pi session; its terminal pane must still exist")
        } else if allowsPromote {
            Button(action: promote) {
                HStack(spacing: 5) {
                    if isPromoting {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text("Continue in agent")
                }
            }
            .buttonStyle(HerdrRowButtonStyle())
            .disabled(isPromoting || session.isEnding || session.hasEnded || session.isRunning || session.isLoadingHistory || session.needsHistoryRefresh)
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
