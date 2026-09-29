import SwiftUI
import UIKit

struct FirstMateChatScreen: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Bindable var store: FirstMateStore
    let target: FirstMateFeatureTarget
    let topmost: Bool
    let openInfo: (FirstMateInspector, String?) -> Void
    var readTrackingEnabled = false
    var back: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false
    @State private var followsLatest = false
    @State private var excerpts: Set<String> = []
    @State private var confirmsCancellation = false
    @State private var archiveRequest: FirstMateMobileArchiveRequest?
    @State private var lease = FirstMateWorkspaceControlLease()
    @State private var sendPulse = 0
    @State private var failurePulse = 0
    @State private var choicePulse = 0
    private var snapshot: FirstMateSnapshot? { store.snapshots[target.featureID] }
    private var conversation: FirstMateConversation? {
        fleet.conversations.first { $0.machineID == target.machineID && $0.featureID == target.featureID }
            ?? fleet.chat.knownPresentation(for: target)
    }
    private var currentOwner: Bool { fleet.store(for: target) === store && fleet.selectedTarget == target && store.selectedFeatureID == target.featureID }
    private var controls: Bool { currentOwner && model.firstMateCanControl(machineID: target.machineID) && snapshot != nil }
    private var closed: Bool { FirstMateMobileTranscriptPolicy.isClosed(snapshot) }
    private var busy: Bool { store.isSending || store.isSubmitting(featureID: target.featureID) }
    private var visibility: FirstMateMobileTranscriptPolicy.Visibility {
        .init(appeared: readTrackingEnabled && appeared && currentOwner, activeScene: scenePhase == .active,
              firstMateTab: model.selectedTab == .firstMate, topmost: topmost,
              covered: !excerpts.isEmpty || archiveRequest != nil || fleet.isCreating || confirmsCancellation || store.resourcePresentation != nil
                || model.agentRequest != nil || model.isCarModePresented || model.isShowingError || model.isSidebarPresented,
              followsLatest: followsLatest)
    }
    private var readID: String? { FirstMateMobileTranscriptPolicy.readMessage(conversation: conversation, visibility: visibility) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            if let snapshot {
                FirstMateChatTranscript(store: store, snapshot: snapshot, conversation: conversation,
                    catalog: FirstMateMobileTranscriptPolicy.mentionCatalog(conversations: fleet.conversations, snapshot: snapshot, owner: target),
                    canControl: controls && !busy && !closed, followsLatest: $followsLatest,
                    openInfo: { openInfo($0, nil) }, sendReply: { send(reply: $0) },
                    presentationChanged: { id, shown in if shown { excerpts.insert(id) } else { excerpts.remove(id) } },
                    fleet: fleet, ownerMachineID: target.machineID,
                    openFeature: { destination in
                        guard destination.machineID == target.machineID else { return }
                        openMention(FirstMateMention.url(for: .feature(featureID: destination.featureID)))
                    })
                    .background(alignment: .top) { HerdrHazeBand() }
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Feature couldn't load", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: { Button("Try again") { Task { await store.refresh() } } }
            } else { ProgressView("Opening your feature…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .herdrFirstMateChrome()
        .toolbar(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .background(FirstMateInteractiveBack())
        .sheet(item: $archiveRequest) { request in FirstMateMobileArchiveSheet(model: model, fleet: fleet, request: request) }
        .onAppear { appeared = true; updateLease() }
        .onDisappear { appeared = false; lease.release() }
        .onChange(of: controls) { _, _ in updateLease() }
        .onChange(of: topmost) { _, _ in updateLease() }
        .onChange(of: store.lifecycle) { _, _ in updateLease() }
        .task(id: FirstMateMobileTranscriptPolicy.ReadAttempt(messageID: readID,
            poll: readID == nil ? nil : fleet.hosts.first(where: { $0.machineID == target.machineID })?.lastUpdated)) {
            guard let readID, visibility.permitsRead, !Task.isCancelled else { return }
            await fleet.chat.markRead(target, through: readID, fleet: fleet)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendPulse)
        .sensoryFeedback(HerdrHaptic.completed.feedback, trigger: choicePulse)
        .sensoryFeedback(HerdrHaptic.attention.feedback, trigger: failurePulse)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "herdr", url.host == "first-mate" else { return .systemAction }
            openMention(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-chat-screen")
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Button { if let back { back() } else { dismiss() } } label: { circle("chevron.left") }
                .accessibilityLabel("Back to conversations").accessibilityIdentifier("first-mate-chat-back")
                .composerLayoutMeasurement(id: "chat-back-control")
            Button { openInfo(.overview, nil) } label: {
                HStack(spacing: 7) {
                    FirstMateEmojiDisc(emoji: conversation?.emoji ?? "✦", size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation?.name ?? snapshot?.feature.title ?? "First Mate")
                            .herdrFont(.body, weight: .semibold).lineLimit(1)
                        Text("\(FirstMateMobileTranscriptPolicy.statusWord(snapshot: snapshot, conversation: conversation)) · \(model.machineName(target.machineID))")
                            .herdrFont(.caption).foregroundStyle(conversation.map { FirstMateChatStatusStyle.color(for: closed ? .done : $0.hudStatus) } ?? HerdrTheme.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
                .padding(.horizontal, 10).frame(minHeight: 44)
                .background(HerdrTheme.codeFill, in: .capsule)
            }
            .accessibilityIdentifier("first-mate-chat-title")
            .composerLayoutMeasurement(id: "chat-title-control")
            Button { openInfo(.overview, nil) } label: { circle("info.circle") }
                .accessibilityLabel("Feature info").accessibilityIdentifier("first-mate-chat-inspector-toggle")
                .composerLayoutMeasurement(id: "chat-info-control")
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                if store.isDemo {
                    Button("Next demo scenario", systemImage: "forward.end", action: store.advanceDemo)
                        .accessibilityIdentifier("first-mate-demo-next")
                }
                Button("Archive…", systemImage: "archivebox") {
                    guard controls else { return }
                    model.beginAppNavigation()
                    archiveRequest = .capture(target: target, fleet: fleet)
                }.disabled(!controls || busy || !store.archiveSupported || snapshot?.feature.isLead == true)
                Button(snapshot?.feature.status == "paused" ? "Resume feature" : "Pause feature", systemImage: snapshot?.feature.status == "paused" ? "play" : "pause") {
                    perform(snapshot?.feature.status == "paused" ? "resume" : "pause")
                }.disabled(!controls || busy || closed || snapshot?.feature.isLead == true)
                Button("Cancel feature", systemImage: "stop.circle", role: .destructive) { confirmsCancellation = true }
                    .disabled(!controls || busy || closed || snapshot?.feature.isLead == true)
            } label: { circle("ellipsis") }
            .accessibilityLabel("Feature options").accessibilityIdentifier("first-mate-feature-options")
            .composerLayoutMeasurement(id: "chat-more-control")
            .confirmationDialog("Cancel this feature?", isPresented: $confirmsCancellation, titleVisibility: .visible) {
                Button("Cancel feature", role: .destructive) { perform("cancel") }
                Button("Keep working", role: .cancel) { }
            } message: { Text("Its conversation, documents, and saved sessions remain available.") }
        }
        .buttonStyle(.plain).foregroundStyle(HerdrTheme.primaryText).padding(.horizontal, 8).padding(.vertical, 5)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane) }
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 40, height: 40)
            .background(HerdrTheme.codeFill, in: .circle).frame(width: 44, height: 44).contentShape(.rect)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = store.sendFailure(for: target.featureID) {
                Text(failure.state.failureMessage ?? "Delivery could not be confirmed.")
                    .herdrFont(.footnote).foregroundStyle(HerdrTheme.warning).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry") { retry(failure) }.disabled(!controls || busy || closed)
                        .accessibilityIdentifier("first-mate-send-retry")
                    Button("Copy") { UIPasteboard.general.string = failure.text }
                }.buttonStyle(HerdrButtonStyle(kind: .outline))
            }
            if closed {
                Text("This feature is closed. Its conversation and evidence remain available.")
                    .herdrFont(.footnote).foregroundStyle(HerdrTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-checkpoint-status")
                    .composerLayoutMeasurement(id: "closed-feature-line")
            } else {
                if let notice {
                    Text(notice).herdrFont(.footnote).foregroundStyle(HerdrTheme.warning)
                        .fixedSize(horizontal: false, vertical: true).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(HerdrTheme.warning.opacity(0.08))
                        .accessibilityIdentifier("first-mate-checkpoint-status")
                }
                FirstMateMessageComposer(text: $store.draft, placeholder: "Message \(conversation?.name ?? "First Mate")",
                    canControl: controls, isSending: busy, send: { _ = send() }, openDocuments: { openInfo(.documents, nil) })
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: 720).frame(maxWidth: .infinity)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).background(HerdrTheme.base) }
    }

    private var notice: String? {
        if let warning = store.runtimeHealth?.warning { return warning }
        if store.error != nil { return "Live execution status is unavailable. Showing the last saved workflow." }
        switch snapshot?.feature.status {
        case "awaiting_direction": return "Your direction is needed before work continues."
        case "paused": return "Work is paused. You can still talk with First Mate."
        case "blocked": return "First Mate needs your help. Tell it how to proceed."
        case "running", "coordinating": return store.runtimeHealth == nil
            ? "Last reported as active. This companion does not report execution health."
            : "Background monitoring is active. You can talk here."
        default:
            if snapshot?.recoveryNeedsDirection == true {
                return store.runtimeHealth?.automaticRecovery == true ? "Checking retained work for a safe automatic continuation."
                    : "Execution was interrupted. Inspect the retained work before asking First Mate to recover."
            }
            return nil
        }
    }
    private func updateLease() {
        if appeared && topmost { lease.update(store: store, available: controls) } else { lease.release() }
    }
    private func perform(_ action: String) {
        guard controls, !busy, !closed, snapshot?.feature.isLead != true else { return }
        let context = store.operationContext
        Task {
            guard controls, !busy, !closed, store.operationContext == context else { return }
            await store.perform(action, expectedContext: context)
            await fleet.didMutate(machineID: target.machineID)
        }
    }
    @discardableResult private func send(reply: String? = nil) -> Bool {
        guard let handle = FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: controls, reply: reply) else { return false }
        if reply == nil { sendPulse += 1 } else { choicePulse += 1 }
        Task {
            let state = await store.completeOutgoingMessage(handle)
            if state?.isFailure == true && store.lifecycle == handle.context.lifecycleIdentity { failurePulse += 1 }
            if fleet.store(for: target) === store && store.lifecycle == handle.context.lifecycleIdentity { await fleet.didMutate(machineID: target.machineID) }
        }
        return true
    }
    private func retry(_ outgoing: FirstMateOutgoingMessage) {
        guard !closed, let handle = FirstMateMobileSubmission.retryHandle(outgoing, store: store, target: target, fleet: fleet, canControl: controls) else { return }
        Task {
            let state = await store.retryOutgoingMessage(handle)
            if state?.isFailure == true && store.lifecycle == handle.context.lifecycleIdentity { failurePulse += 1 }
            if fleet.store(for: target) === store && store.lifecycle == handle.context.lifecycleIdentity { await fleet.didMutate(machineID: target.machineID) }
        }
    }
    private func openMention(_ url: URL) {
        guard appeared, topmost, model.selectedTab == .firstMate else { return }
        FirstMateMobileOwnedNavigation.open(url, owner: target, store: store, model: model)
    }
}
