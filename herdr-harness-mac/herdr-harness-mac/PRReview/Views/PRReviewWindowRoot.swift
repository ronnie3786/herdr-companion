import AppKit
import SwiftUI

/// The root of one popped-out PR Review window.
///
/// Window creation is deliberately outside the main shell: the review stays
/// attached to the machine it was opened from, and its own `PRReviewWindowSession`
/// owns refresh, polling, and presentation flags. The main window may switch
/// chats, hosts, or selections underneath without changing this window.
struct PRReviewWindowRoot: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    let target: PRReviewWindowTarget

    @Environment(\.openWindow) private var openWindow
    @State private var session: PRReviewWindowSession
    @State private var capturedSeed: PRReviewWindowSeed?
    @State private var didCaptureSeed = false

    init(model: HerdrAppModel, shell: HerdrShellState, target: PRReviewWindowTarget) {
        self.model = model
        self.shell = shell
        self.target = target
        _session = State(initialValue: PRReviewWindowSession(target: target))
    }

    var body: some View {
        Group {
            switch session.hostState {
            case .checking:
                loadingView("Opening \(machineName)…")
            case .missingHost:
                unavailableView(
                    title: "Machine unavailable",
                    detail: "\(machineName) is no longer configured. Add it in Settings → Machines, or close this review window."
                )
            case .unconfigured:
                unavailableView(
                    title: "PR Review is not configured",
                    detail: "Add a companion token for \(machineName) in Settings → Machines, then try again."
                )
            case .demo, .available:
                content
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(HerdrTheme.graphite)
        .foregroundStyle(HerdrTheme.text)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(target.windowAccessibilityIdentifier)
        .task(id: hostProbe) {
            await activate()
        }
        .task(id: model.prReviewRefreshTick) {
            await session.refreshFromEventTick()
        }
        .onDisappear {
            session.stop()
        }
    }

    private var content: some View {
        PRReviewContainerView(
            store: session.store,
            canControl: session.canControl,
            openURL: { url in Task { try? await ActiveWorkLinkOpener.open(url) } },
            askAI: { selection, view, rect in
                guard let review = session.store.snapshot?.review ?? session.store.selectedReview else { return }
                Task {
                    await model.presentPRReviewQuestion(
                        machineID: target.machineID,
                        review: review,
                        selection: selection,
                        anchor: (view, rect)
                    )
                }
            },
            questionDraftChanged: { session.setQuestionDraft($0) },
            setCreating: { session.setCreating($0) },
            openPane: { paneID, machineID in
                NSApp.activate()
                openWindow(id: HerdrWindowID.main)
                shell.openPane(rawPaneID: paneID, machineID: machineID ?? target.machineID, model: model)
            },
            setAddingSkill: { session.setAddingSkill($0) },
            navigationTitle: windowTitle
        )
    }

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .herdrFont(.caption, monospaced: true, weight: .medium)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func unavailableView(title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "arrow.triangle.pull")
        } description: {
            Text(detail)
        }
        .foregroundStyle(HerdrTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activate() async {
        let seed: PRReviewWindowSeed?
        if didCaptureSeed {
            seed = capturedSeed
        } else {
            didCaptureSeed = true
            capturedSeed = PRReviewWindowSeed.capture(from: shell.prReview, target: target)
            seed = capturedSeed
        }
        let resolution = resolvedHost
        await session.activate(
            identity: hostProbe.identifier,
            hostState: resolution.state,
            client: resolution.client,
            seed: seed
        )
    }

    private var resolvedHost: (state: PRReviewWindowHostState, client: (any PRReviewClient)?) {
        let probe = hostProbe
        let state = PRReviewWindowHostResolver.resolve(
            isDemoTarget: probe.isDemoTarget,
            targetMachineExists: probe.machineExists,
            hasConfiguration: probe.configurationURL != nil
        )
        guard state == .available,
              let configuration = model.prReviewConfiguration(pinnedMachineID: target.machineID)
        else {
            return (state, nil)
        }
        return (.available, HerdrAPIClient(configuration: configuration))
    }

    private var hostProbe: PRReviewWindowHostProbe {
        let isDemoTarget = model.isDemoMode && target.machineID == "demo"
        let machineExists = model.machines.contains { $0.id == target.machineID }
        let configuration = isDemoTarget ? nil : model.prReviewConfiguration(pinnedMachineID: target.machineID)
        return PRReviewWindowHostProbe(
            isDemoTarget: isDemoTarget,
            machineExists: machineExists,
            configurationURL: configuration?.baseURL.absoluteString
        )
    }

    private var machineName: String {
        model.machines.first { $0.id == target.machineID }?.name ?? "This machine"
    }

    private var windowTitle: String {
        if let review = session.store.snapshot?.review ?? session.store.selectedReview {
            return PRReviewHeaderText.title(for: review)
        }
        return "PR Review"
    }
}

/// Equality of this probe is what re-activates a window: a pinned host that is
/// removed and later re-added changes the probe, while the main window's host
/// selector, selection, or chat navigation does not.
private struct PRReviewWindowHostProbe: Equatable {
    let isDemoTarget: Bool
    let machineExists: Bool
    let configurationURL: String?

    var identifier: String {
        "\(isDemoTarget)|\(machineExists)|\(configurationURL ?? "-")"
    }
}
