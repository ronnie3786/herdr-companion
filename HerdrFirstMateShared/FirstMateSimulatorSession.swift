import CoreGraphics
import Foundation
import Observation

/// One simulator view (a window on the Mac, a full-screen cover on iPad and
/// iPhone): a saved build shown in a live simulator on the feature's machine.
/// On the Mac the value is the window's identity, so opening the same build
/// again focuses its window instead of starting a second simulator.
struct FirstMateSimulatorWindowTarget: Codable, Hashable, Identifiable, Sendable {
    let machineID: String
    let featureID: String
    let buildID: String

    var id: String { [machineID, featureID, buildID].joined(separator: "|") }
}

/// Drives one simulator window: asks the companion to open (reuse or start) a
/// preview of the exact build, follows it until it runs, streams it, and
/// stops it only when asked. Closing the window never stops the simulator:
/// the companion's idle policy does that once nobody watches.
@MainActor @Observable
final class FirstMateSimulatorSession {
    enum Phase: Equatable {
        case opening
        case starting
        case running
        case stopping
        case stopped
        case failed(String)
        case unavailable(String)
    }

    let target: FirstMateSimulatorWindowTarget
    let machineName: String
    let isDemo: Bool
    private(set) var phase: Phase = .opening
    private(set) var preview: FirstMateSimulatorPreview?
    private(set) var build: FirstMateSimulatorBuild?
    private(set) var feature: FirstMateSimulatorFeatureSummary?
    private(set) var status: FirstMateSimulatorStatus?
    /// A one-line note about something the companion did for this open, such
    /// as shutting down an idle preview to make room.
    private(set) var notice: String?
    /// Previews already running when the cap refused a new one.
    private(set) var capacity: [FirstMateSimulatorPreview] = []
    private(set) var isSubmitting = false
    private(set) var stream: SimulatorStreamController?
    /// Demo mode's stand-in for the live picture.
    private(set) var demoFrame: CGImage?
    /// Demo mode's picture for a caller's own synthetic build.
    @ObservationIgnored private var demoScreen: CGImage?
    /// True while the window has been hidden long enough that its stream is paused.
    private(set) var isPausedWhileHidden = false

    /// Someone deleted this preview's simulator in SimPortal (or is deleting it) to free disk.
    var simulatorDeleted: Bool {
        ["simulator_deleted", "delete_queued", "deleting_simulator"].contains(preview?.status ?? "")
    }

    @ObservationIgnored private let api: FirstMateSimulatorAPI?
    @ObservationIgnored private let transportFactory: SimulatorStreamTransportFactory
    @ObservationIgnored private let pauseDelay: Duration
    @ObservationIgnored private var openRequestID = UUID().uuidString.lowercased()
    @ObservationIgnored private var stopRequestID: String?
    @ObservationIgnored private var streamPreviewID: String?
    @ObservationIgnored private var hiddenTask: Task<Void, Never>?
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    /// Set by an action so the follow loop refreshes now instead of at its next tick.
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private let onChange: @MainActor () -> Void

    static let hiddenPauseDelay: Duration = .seconds(60)

    init(target: FirstMateSimulatorWindowTarget, machineName: String, api: FirstMateSimulatorAPI?, isDemo: Bool,
         transportFactory: @escaping SimulatorStreamTransportFactory = URLSessionSimulatorStreamTransport.factory,
         hiddenPauseDelay: Duration = FirstMateSimulatorSession.hiddenPauseDelay,
         onChange: @escaping @MainActor () -> Void = {}) {
        self.target = target
        self.machineName = machineName
        self.api = api
        self.transportFactory = transportFactory
        self.pauseDelay = hiddenPauseDelay
        self.isDemo = isDemo
        self.onChange = onChange
        if isDemo {
            presentDemo()
        } else if api == nil {
            phase = .unavailable("\(machineName) isn't connected. Check Settings → Machines.")
        }
    }

    // MARK: Lifecycle

    /// Opens the preview and follows it until the window closes (task cancellation).
    func run() async {
        guard !isDemo, api != nil else { return }
        if preview == nil, case .opening = phase { await open() }
        while !Task.isCancelled {
            if isPausedWhileHidden {
                await sleep(.seconds(86_400))
                continue
            }
            await refresh()
            let interval: Duration = switch phase {
            case .opening, .starting, .stopping: .seconds(1)
            case .running: .seconds(5)
            case .stopped, .failed, .unavailable: .seconds(15)
            }
            await sleep(interval)
        }
    }

    /// The window closed: stop watching. The simulator keeps running until
    /// the companion's idle policy or an explicit Stop shuts it down.
    func close() {
        hiddenTask?.cancel()
        hiddenTask = nil
        waitTask?.cancel()
        waitTask = nil
        stream?.disconnect()
        stream = nil
        streamPreviewID = nil
    }

    /// The window was hidden or shown. A hidden window stops streaming after a
    /// minute on Mac, or immediately on iOS, to stop unnecessary network and decoding work.
    func setVisible(_ visible: Bool) {
        hiddenTask?.cancel()
        hiddenTask = nil
        if visible {
            if isPausedWhileHidden {
                isPausedWhileHidden = false
                stream?.connect()
                wakeLoop()
            }
            return
        }
        if pauseDelay == .zero {
            pauseWhileHidden()
            return
        }
        hiddenTask = Task { [weak self, pauseDelay] in
            try? await Task.sleep(for: pauseDelay)
            guard !Task.isCancelled, let self else { return }
            self.pauseWhileHidden()
        }
    }

    private func pauseWhileHidden() {
        isPausedWhileHidden = true
        stream?.pause()
        wakeLoop()
    }

    // MARK: Actions

    func stop() async {
        if isDemo {
            presentDemoStopped()
            return
        }
        guard let api, let preview, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let requestID = stopRequestID ?? UUID().uuidString.lowercased()
        stopRequestID = requestID
        do {
            let result = try await api.stop(featureID: target.featureID, previewID: preview.id, requestID: requestID)
            apply(result.preview)
            notice = nil
        } catch let failure as FirstMateSimulatorError {
            if failure.isDefinite { stopRequestID = nil }
            notice = failure.message
        } catch {
            notice = "Couldn't reach the companion to stop the simulator."
        }
        wakeLoop()
    }

    /// Starts a new simulator after the last one was stopped or failed.
    func startAgain() async {
        guard !isSubmitting else { return }
        if isDemo {
            presentDemoRunning()
            return
        }
        openRequestID = UUID().uuidString.lowercased()
        stopRequestID = nil
        preview = nil
        capacity = []
        notice = nil
        phase = .opening
        await open()
        wakeLoop()
    }

    /// Retries the same open after a refusal that may have cleared (for
    /// example another simulator was stopped to make room).
    func retryOpen() async {
        guard !isSubmitting else { return }
        openRequestID = UUID().uuidString.lowercased()
        capacity = []
        phase = .opening
        await open()
        wakeLoop()
    }

    /// "Receipt export · Round 2: export sheet"
    var windowTitle: String {
        let feature = self.feature?.label ?? self.feature?.title ?? "First Mate"
        return [feature, build?.checkpointLabel ?? "Simulator"].joined(separator: " · ")
    }

    /// The browser link that can work from this Mac, if SimPortal offered one.
    var browserURL: URL? {
        guard let links = preview?.browserLinks else { return nil }
        if api?.isLocal == true, let local = links.local { return local }
        return links.tailnet
    }

    var browserUnavailableReason: String {
        if preview?.udid == nil { return "Available once the simulator is created." }
        return "SimPortal on \(machineName) has no link this Mac can open. Enable its tailnet link there (simportal tailscale enable)."
    }

    // MARK: Companion

    private func open() async {
        guard let api else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await api.open(featureID: target.featureID, buildID: target.buildID, requestID: openRequestID)
            capacity = []
            if !result.stoppedToMakeRoom.isEmpty {
                let count = result.stoppedToMakeRoom.count
                notice = count == 1 ? "Shut down an idle simulator to make room." : "Shut down \(count) idle simulators to make room."
            }
            apply(result.preview)
            onChange()
        } catch let failure as FirstMateSimulatorError {
            if failure.code == "simulator_capacity" {
                capacity = failure.running
            }
            phase = failure.status == nil ? .failed(failure.message) : .unavailable(failure.message)
            // A refusal is final for this request ID; a new attempt needs a new one.
            if failure.isDefinite { openRequestID = UUID().uuidString.lowercased() }
        } catch {
            phase = .failed("Couldn't reach the companion on \(machineName).")
        }
    }

    private func refresh() async {
        guard let api else { return }
        guard let current = preview else {
            // No preview yet: show the build and the machine's status while waiting.
            if build == nil || status == nil, let list = try? await api.builds(featureID: target.featureID) {
                build = list.builds.first { $0.id == target.buildID }
                status = list.simulator
            }
            return
        }
        do {
            let detail = try await api.preview(featureID: target.featureID, previewID: current.id)
            if let build = detail.build { self.build = build }
            if let feature = detail.feature { self.feature = feature }
            if let simulator = detail.simulator { status = simulator }
            apply(detail.preview)
        } catch let failure as FirstMateSimulatorError where failure.status == 404 {
            phase = .unavailable("This simulator is no longer known to the companion.")
            close()
        } catch {
            // Transient: keep the last state and try again on the next tick.
        }
    }

    private func apply(_ preview: FirstMateSimulatorPreview) {
        let previousPhase = phase
        self.preview = preview
        phase = switch preview.phase {
        case "starting": .starting
        case "running": .running
        case "stopping": .stopping
        case "stopped": .stopped
        case "cancelled": .stopped
        case "failed": .failed(preview.error?.message ?? preview.operation?.error?.message ?? "SimPortal couldn't start the simulator.")
        case "uncertain": .failed("SimPortal lost track of the last step. Check the simulator in SimPortal before retrying.")
        case "unavailable": .unavailable("SimPortal on \(machineName) is not the server that started this simulator.")
        default: .failed("The simulator is in an unexpected state (\(preview.status)).")
        }
        if phase != previousPhase { onChange() }
        syncStream()
    }

    private func syncStream() {
        guard let api, let preview else { return }
        let wanted = preview.streamAvailable && (phase == .starting || phase == .running)
        if wanted {
            if streamPreviewID != preview.id {
                stream?.disconnect()
                let featureID = target.featureID, previewID = preview.id
                let controller = SimulatorStreamController(
                    requestFactory: { try api.streamRequest(featureID: featureID, previewID: previewID) },
                    transportFactory: transportFactory,
                    quality: api.isLocal ? .high : .balanced)
                stream = controller
                streamPreviewID = preview.id
                if isPausedWhileHidden {
                    controller.pause()
                } else {
                    controller.connect()
                }
            }
        } else if stream != nil, phase != .opening {
            stream?.disconnect()
            stream = nil
            streamPreviewID = nil
        }
    }

    /// One cancellable sleep, woken by actions or visibility changes, without polling.
    private func sleep(_ duration: Duration) async {
        guard !refreshRequested, !Task.isCancelled else {
            refreshRequested = false
            return
        }
        let task = Task<Void, Never> { try? await Task.sleep(for: duration) }
        waitTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        waitTask = nil
        refreshRequested = false
    }

    private func wakeLoop() {
        refreshRequested = true
        waitTask?.cancel()
    }

    // MARK: Demo

    private func presentDemo() {
        let demo = FirstMateSimulatorDemo.preview(featureID: target.featureID, buildID: target.buildID)
        let builds = FirstMateSimulatorDemo.builds(featureID: target.featureID, visitIDs: [])
        build = builds.first { $0.id == target.buildID } ?? builds.first
        feature = FirstMateSimulatorFeatureSummary(id: target.featureID, title: "Receipt export", label: "Receipt export", emoji: "🧾")
        status = FirstMateSimulatorDemo.status
        preview = demo
        phase = .running
        demoFrame = FirstMateSimulatorDemo.screenImage()
    }

    /// Demo mode with the caller's own synthetic build and picture (the iOS
    /// demo's builds), running unless `startingAt` names a start step.
    func presentDemo(build: FirstMateSimulatorBuild, feature: FirstMateSimulatorFeatureSummary?, screen: CGImage?,
                     startingAt step: String? = nil) {
        guard isDemo else { return }
        self.build = build
        if let feature { self.feature = feature }
        demoScreen = screen
        if let step { presentDemoStarting(at: step) } else { presentDemoRunning() }
    }

    /// Demo mode: the simulator is running and shows its synthetic picture.
    func presentDemoRunning() {
        guard isDemo else { return }
        preview = FirstMateSimulatorDemo.preview(featureID: target.featureID, buildID: target.buildID)
        phase = .running
        notice = nil
        demoFrame = demoScreen ?? FirstMateSimulatorDemo.screenImage()
    }

    /// Demo mode shows the loading timeline at a given step instead of a picture.
    func presentDemoStarting(at step: String) {
        guard isDemo else { return }
        preview = FirstMateSimulatorDemo.preview(featureID: target.featureID, buildID: target.buildID, startingAt: step)
        phase = .starting
        demoFrame = FirstMateSimulatorDemo.startSteps.firstIndex(of: step).map { $0 >= 4 } == true
            ? (demoScreen ?? FirstMateSimulatorDemo.screenImage()) : nil
    }

    /// Demo mode: Stop shut the simulator down.
    func presentDemoStopped() {
        guard isDemo else { return }
        preview = FirstMateSimulatorDemo.stoppedPreview(featureID: target.featureID, buildID: target.buildID)
        phase = .stopped
        demoFrame = nil
    }

    /// Demo mode: the simulator was deleted on SimPortal's Machines page.
    func presentDemoDeleted() {
        guard isDemo else { return }
        preview = FirstMateSimulatorDemo.deletedPreview(featureID: target.featureID, buildID: target.buildID)
        phase = .stopped
        demoFrame = nil
    }
}
