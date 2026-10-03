import AppKit
import SwiftUI

private struct ShellRefreshTaskIdentity: Equatable {
    let connection: ShellRefreshConnectionIdentity
    let inbox: WorkInboxConnectionIdentity
    let canPoll: Bool
}

private struct ShellReviewRequestIdentity: Equatable {
    let requestID: UUID?
    let machineID: String?
    let connection: ShellRefreshConnectionIdentity
}

/// Mounted above destination switching, so Home and tab badges never rely on
/// mounting Watchers, the Chats navigator, or the PR Review rail.
struct ShellRefreshModifier: ViewModifier {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @State private var windowAllowsPolling = false

    private var canPoll: Bool { model.hasCompletedSetup && windowAllowsPolling && !FirstMateFleetDriver.isHostedByTests }
    private var identity: ShellRefreshTaskIdentity {
        .init(connection: .current(model: model), inbox: model.workInboxConnectionIdentity, canPoll: canPoll)
    }

    func body(content: Content) -> some View {
        content
            .background {
                ShellRefreshWindowObserver { windowAllowsPolling = $0 }
                    .frame(width: 0, height: 0)
            }
            .task(id: identity) {
                guard !FirstMateFleetDriver.isHostedByTests else { return }
                await shell.refreshCoordinator.run(model: model, shell: shell, canPoll: canPoll)
            }
            .task(id: model.watchersRefreshTick) {
                guard canPoll, model.watchersRefreshTick > 0 else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await shell.watchers.refresh()
            }
            .task(id: model.prReviewRefreshTick) {
                guard canPoll, model.prReviewRefreshTick > 0 else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await shell.prReviewFleet.refresh()
                await shell.refreshCoordinator.refreshSummaries(model: model, shell: shell)
            }
            .task(id: model.alerts) {
                guard canPoll else { return }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await model.refreshActivityFeed()
            }
            .onChange(of: shell.prReview.reviews.map(\.id)) { _, _ in
                guard canPoll else { return }
                Task { await shell.prReviewFleet.refresh() }
            }
            .onChange(of: model.prReviewMachineRevision) { _, _ in
                shell.prReviewHostSettingsDidChange()
            }
            .task(id: ShellReviewRequestIdentity(requestID: shell.prReviewOpenRequest?.id,
                                                 machineID: shell.prReviewMachineID,
                                                 connection: .current(model: model))) {
                await shell.applyPRReviewNavigationRequest(model: model)
            }
            .task(id: model.isDemoMode) {
                if model.isDemoMode, ProcessInfo.processInfo.arguments.contains("-HerdrWatchersDemo") {
                    shell.show(.watchers, model: model)
                }
            }
    }
}

/// The main window need not be key (a pop-out may be key), but minimized,
/// ordered-out, closed, and inactive-app windows do not keep polling.
private struct ShellRefreshWindowObserver: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(changed: changed) }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: ObserverView, coordinator: Void) { view.stop() }

    final class ObserverView: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { changed(false); return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let isClosing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        if isClosing { self?.changed(false) }
                        else { self?.report() }
                    }
                })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private func report() {
            changed(window?.isVisible == true && window?.isMiniaturized == false
                    && NSApplication.shared.isActive && !NSApplication.shared.isHidden)
        }
    }
}
