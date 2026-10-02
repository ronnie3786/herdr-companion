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
    var followsLeadChoice = false
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.firstMateRegularChatControls) private var columns
    @Environment(\.firstMateInspectorContext) private var inspectorContext
    @State private var appeared = false
    @State private var followsLatest = false
    @State private var readLayout: FirstMateMobileTranscriptPolicy.ReadLayout?
    @State private var expandedReplies: Set<String> = []
    @State private var excerpts: Set<String> = []
    @State private var confirmsCancellation = false
    @State private var archiveRequest: FirstMateMobileArchiveRequest?
    @State private var lease = FirstMateWorkspaceControlLease()
    @State private var sendPulse = 0
    @State private var failurePulse = 0
    @State private var choicePulse = 0
    private var material: FirstMateMobileComposerDraft { fleet.chat.composerDrafts.draft(for: target, store: store) }
    private var snapshot: FirstMateSnapshot? { store.snapshots[target.featureID] }
    private var conversation: FirstMateConversation? {
        fleet.chat.conversation(for: target, fleet: fleet)
    }
    private var isLead: Bool { snapshot?.feature.isLead == true }
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
    private var readAttempt: FirstMateMobileTranscriptPolicy.ReadAttempt? {
        guard let snapshot, let readLayout, readLayout.storeID == ObjectIdentifier(store), readLayout.lifecycle == store.lifecycle,
              readLayout.expandedReplies == expandedReplies else { return nil }
        let messages = FirstMateTranscriptLayout.orderedMessages(store: store, snapshot: snapshot)
        let optimistic = fleet.chat.readState.overrides[.init(machineID: target.machineID, featureID: target.featureID)]
        guard let id = FirstMateMobileTranscriptPolicy.readMessage(conversation: conversation, visibility: visibility,
            messages: messages, layout: readLayout, optimisticMessageID: optimistic) else { return nil }
        return .init(messageID: id, layout: readLayout, retryAt: fleet.chat.readRetryAt(target, through: id))
    }

    var body: some View {
        // A task may start after observable state has advanced. Its operation
        // must use the exact value that supplied this render's task identity.
        let attempt = readAttempt
        Group {
            if let snapshot {
                FirstMateChatTranscript(store: store, snapshot: snapshot, conversation: conversation,
                    catalog: FirstMateMobileTranscriptPolicy.mentionCatalog(conversations: fleet.conversations, snapshot: snapshot, owner: target),
                    canControl: controls && !busy && !closed, followsLatest: $followsLatest, readLayout: $readLayout, expandedReplies: $expandedReplies,
                    openInfo: { openInfo($0, nil) }, sendReply: { send(reply: $0) },
                    presentationChanged: { id, shown in if shown { excerpts.insert(id) } else { excerpts.remove(id) } },
                    fleet: fleet, ownerMachineID: target.machineID,
                    openFeature: { destination in
                        guard destination.machineID == target.machineID else { return }
                        openMention(FirstMateMention.url(for: .feature(featureID: destination.featureID)))
                    }, canRate: controls)
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Feature couldn't load", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: { Button("Try again") { Task { await store.refresh() } } }
            } else { ProgressView("Opening your feature…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bars float over the dusk as Liquid Glass controls with no band; the
        // transcript fades out at their edges (`herdrEdgeFade`).
        .safeAreaBar(edge: .top, spacing: 0) { if isLead { leadBar } else { bar } }
        .safeAreaBar(edge: .bottom, spacing: 0) { composer }
        .background {
            ZStack(alignment: .top) {
                HerdrGlassBackground(level: HerdrTheme.Glass.pane)
                HerdrHazeBand()
            }
            .ignoresSafeArea()
        }
        .herdrFirstMateChrome()
        .toolbar(.hidden, for: .navigationBar)
        .toolbarVisibility(embedded ? .visible : .hidden, for: .tabBar)
        .background(FirstMateInteractiveBack())
        .sheet(item: $archiveRequest) { request in FirstMateMobileArchiveSheet(model: model, fleet: fleet, request: request) }
        .onAppear { appeared = true; updateLease() }
        .onDisappear { appeared = false; lease.release() }
        .onChange(of: controls) { _, _ in updateLease() }
        .onChange(of: topmost) { _, _ in updateLease() }
        .onChange(of: store.lifecycle) { _, _ in updateLease() }
        .task(id: attempt) {
            guard let attempt, visibility.permitsRead, !Task.isCancelled else { return }
            await fleet.chat.trackRead(target, through: attempt.messageID, store: store, fleet: fleet)
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
        HStack(spacing: columns == nil ? 6 : 8) {
            leadingControl
            Button { showOverview() } label: {
                HStack(spacing: columns == nil ? 7 : 10) {
                    FirstMateEmojiDisc(emoji: conversation?.emoji ?? "✦", size: columns == nil ? 28 : 36)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(conversation?.name ?? snapshot?.feature.title ?? "First Mate")
                                .herdrFont(.body, weight: .semibold).lineLimit(1)
                            // iPhone's bar also carries Git, ⋯ and Info, so the name keeps the chevron's room.
                            if columns != nil {
                                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(HerdrTheme.iconTint)
                            }
                        }
                        titleSubtitle.lineLimit(1)
                    }
                    // iPad: the pill hugs its name, as in the prototype; the
                    // bar's spacer pushes Git, ⋯ and the inspector right.
                    if columns == nil { Spacer(minLength: 0) }
                }
                .padding(.leading, columns == nil ? 8 : 6).padding(.trailing, columns == nil ? 12 : 18)
                .frame(minHeight: columns == nil ? 44 : 48)
                .herdrControlGlass(in: .capsule)
            }
            .accessibilityIdentifier("first-mate-chat-title")
            .composerLayoutMeasurement(id: "chat-title-control")
            if columns != nil { Spacer(minLength: 0) }
            if let inspectorContext {
                Button { inspectorContext.openGit(FirstMateGitTarget(feature: target, featureTitle: inspectorContext.featureTitle)) } label: {
                    circle("arrow.triangle.branch")
                }
                .accessibilityLabel("Git").accessibilityIdentifier("first-mate-chat-git")
                .composerLayoutMeasurement(id: "chat-git-control")
            }
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
            inspectorControl(label: "Feature info")
        }
        .buttonStyle(.plain).foregroundStyle(HerdrTheme.primaryText).padding(.horizontal, columns == nil ? 10 : 12).padding(.top, 2).padding(.bottom, 6)
    }

    /// The status word in its color, then (iPad) the step, then the machine.
    private var titleSubtitle: some View {
        let status = FirstMateMobileTranscriptPolicy.statusWord(snapshot: snapshot, conversation: conversation)
        let color = conversation.map { FirstMateChatStatusStyle.color(for: closed ? .done : $0.hudStatus) } ?? HerdrTheme.secondaryText
        let machine = model.machineName(target.machineID)
        let step = columns == nil ? nil : conversation.flatMap(FirstMateNowCard.stepLine)
        return Group {
            if columns == nil {
                Text("\(status) · \(machine)").foregroundStyle(color)
            } else {
                Text("\(Text(status).foregroundStyle(color)) · \(step.map { "\($0) · " } ?? "")\(machine)")
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
        }
        .herdrFont(.caption)
    }

    private var leadBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                leadingControl
                if followsLeadChoice {
                    FirstMateLeadMachineMenu(model: model, fleet: fleet)
                } else {
                    HStack(spacing: 7) { FirstMateFaceOrb(size: 28); Text("My First Mate").herdrFont(.body, weight: .semibold); Spacer(minLength: 0) }
                        .padding(.leading, 8).padding(.trailing, 14).frame(maxWidth: .infinity, minHeight: 44)
                        .herdrControlGlass(in: .capsule, interactive: false)
                }
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refreshLead() } }
                    #if DEBUG
                    if fleet.isDemo, ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateLeadScenarios") {
                        Button("Fail preferred LIST poll") { fleet.failDemoLeadPoll() }
                        Button("Recover preferred machine") { fleet.recoverDemoLead() }
                    }
                    #endif
                } label: { circle("ellipsis") }
                .accessibilityLabel("First Mate options").accessibilityIdentifier("first-mate-lead-options")
                .composerLayoutMeasurement(id: "chat-more-control")
                inspectorControl(label: "First Mate overview")
            }
            Text("\(model.machineName(target.machineID)) · \(FirstMateLeadBriefing.headerSubtitle(conversations: fleet.conversations))")
                .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 56)
                .accessibilityIdentifier("first-mate-lead-owner")
            if followsLeadChoice, fleet.leadChoice.isFallback, let preferred = fleet.leadChoice.preferred {
                Text("\(model.machineName(preferred)) is offline. \(model.machineName(target.machineID)) is standing in.")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.warning).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 56)
                    .accessibilityIdentifier("first-mate-lead-offline")
            }
        }
        .buttonStyle(.plain).foregroundStyle(HerdrTheme.primaryText).padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6)
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium)).herdrGlassCircle(44)
    }

    /// iPad: the list toggle. iPhone: Back.
    @ViewBuilder private var leadingControl: some View {
        if let columns {
            Button(action: columns.toggleList) { circle("sidebar.left") }
                .accessibilityLabel(columns.listIsRail ? "Show the conversation list" : "Fold the list into a rail")
                .accessibilityIdentifier("first-mate-chat-list-toggle")
                .composerLayoutMeasurement(id: "chat-back-control")
        } else {
            Button { if let back { back() } else { dismiss() } } label: { circle("chevron.left") }
                .accessibilityLabel("Back to conversations").accessibilityIdentifier("first-mate-chat-back")
                .composerLayoutMeasurement(id: "chat-back-control")
        }
    }

    /// The trailing control, after ⋯: the iPad inspector toggle (accent while
    /// the inspector shows), or iPhone's Info button that pushes Info.
    @ViewBuilder private func inspectorControl(label: String) -> some View {
        if let columns {
            Button(action: columns.toggleInspector) {
                Image(systemName: "sidebar.right").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(columns.inspectorOpen ? HerdrTheme.accent : HerdrTheme.primaryText)
                    .herdrGlassCircle(44)
                    .overlay { if columns.inspectorOpen { Circle().fill(HerdrTheme.accent.opacity(0.16)).frame(width: 44, height: 44).allowsHitTesting(false) } }
            }
            .accessibilityLabel(columns.inspectorOpen ? "Hide the inspector" : "Show the inspector")
            .accessibilityIdentifier("first-mate-chat-inspector-toggle")
            .composerLayoutMeasurement(id: "chat-info-control")
        } else {
            Button { openInfo(.overview, nil) } label: { circle("info.circle") }
                .accessibilityLabel(label).accessibilityIdentifier("first-mate-chat-inspector-toggle")
                .composerLayoutMeasurement(id: "chat-info-control")
        }
    }

    /// The title opens Overview: in the iPad inspector, or pushed on iPhone.
    private func showOverview() {
        if let columns { columns.showInspector(.overview) } else { openInfo(.overview, nil) }
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
                    FirstMateChatNotice(text: notice, paused: snapshot?.feature.status == "paused" && store.runtimeHealth?.warning == nil && store.error == nil)
                }
                FirstMateConversationComposer(model: model, fleet: fleet, store: store, material: material, target: target,
                    placeholder: isLead ? "Ask First Mate about any feature…" : "Message \(conversation?.name ?? "First Mate")",
                    canControl: controls, active: appeared && topmost, send: { send() },
                    openDocuments: isLead ? nil : { openInfo(.documents, nil) },
                    presentationChanged: { shown in if shown { excerpts.insert("composer-sheet") } else { excerpts.remove("composer-sheet") } })
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
        .frame(maxWidth: 720).frame(maxWidth: .infinity)
    }

    private var notice: String? {
        if isLead { return store.error == nil ? nil : "The owning companion is unavailable. Showing its saved conversation." }
        if let warning = store.runtimeHealth?.warning { return warning }
        if store.error != nil { return "Live execution status is unavailable. Showing the last saved workflow." }
        // The Mac notice band: execution warnings, blocked work, interrupted
        // recovery, and pause. The header's status already says "Your turn"
        // or "Planning", so routine states add no band.
        switch snapshot?.feature.status {
        case "paused": return "Work is paused. You can still talk with First Mate."
        case "blocked":
            return snapshot?.events.last(where: { $0.type == "reliability.blocked" })?.summary
                ?? "Work is blocked. Review the retained evidence and give First Mate direction."
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
        let material = material
        guard let handle = FirstMateMobileSubmission.begin(store: store, target: target, fleet: fleet, canControl: controls, reply: reply, material: material) else { return false }
        if reply == nil { sendPulse += 1 } else { choicePulse += 1 }
        Task {
            let state = await store.completeOutgoingMessage(handle)
            if reply == nil { material.settle(handle, state: state, store: store) }
            if state?.isFailure == true && store.lifecycle == handle.context.lifecycleIdentity { failurePulse += 1 }
            if fleet.store(for: target) === store && store.lifecycle == handle.context.lifecycleIdentity { await fleet.didMutate(machineID: target.machineID) }
        }
        return true
    }
    private func retry(_ outgoing: FirstMateOutgoingMessage) {
        let material = material
        guard !closed, let handle = FirstMateMobileSubmission.retryHandle(outgoing, store: store, target: target, fleet: fleet, canControl: controls) else { return }
        material.prepareRetry(handle, store: store)
        Task {
            let state = await store.retryOutgoingMessage(handle)
            material.settle(handle, state: state, store: store)
            if state?.isFailure == true && store.lifecycle == handle.context.lifecycleIdentity { failurePulse += 1 }
            if fleet.store(for: target) === store && store.lifecycle == handle.context.lifecycleIdentity { await fleet.didMutate(machineID: target.machineID) }
        }
    }
    private func openMention(_ url: URL) {
        guard appeared, topmost, model.selectedTab == .firstMate else { return }
        FirstMateMobileOwnedNavigation.open(url, owner: target, store: store, model: model)
    }
}

/// The Mac execution notice: an icon and one short fact above the composer.
private struct FirstMateChatNotice: View {
    let text: String
    let paused: Bool
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: paused ? "pause.circle" : "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
        }
        .herdrFont(.footnote).foregroundStyle(paused ? HerdrTheme.secondaryText : HerdrTheme.warning)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((paused ? HerdrTheme.inkFill(0.04) : HerdrTheme.warning.opacity(0.10)), in: .rect(cornerRadius: 14))
        .herdrControlGlass(in: .rect(cornerRadius: 14), interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-mate-checkpoint-status")
    }
}
