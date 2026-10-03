import CoreGraphics
import Foundation
import Observation

/// Thrown by a request factory that knows reconnecting is pointless, for
/// example because the preview was deleted.
enum SimulatorStreamStop: Error, Equatable, Sendable {
    case ended(reason: String)
    case failed(message: String)
}

/// The screen view that holds keys and touches for a stream.
@MainActor
protocol SimulatorStreamInputSink: AnyObject {
    /// The server already released everything (the socket closed or the
    /// stream helper restarted): forget held keys and touches without sending.
    func streamDidReleaseInput()
}

/// An agent's API action on the simulator, as the stream last reported one.
struct SimulatorAgentActivity: Equatable, Sendable {
    var action: SimulatorAgentAction
    var receivedAt: Date
}

/// One simulator's live stream through the companion's SimPortal relay:
/// connecting, reconnecting, decoding and forwarding input.
///
/// A running connection keeps the controller alive, and a main-actor class
/// cannot disconnect from `deinit`, so the owner must call `disconnect()`.
@MainActor @Observable
final class SimulatorStreamController {
    enum State: Equatable, Sendable {
        case idle
        case connecting
        /// The socket is open but there is nothing to show yet: the simulator
        /// is not booted (`Booting`, `Shutdown`, ...), or its stream helper is
        /// restarting (`Restarting`). The stream resumes by itself.
        case waitingForDevice(state: String)
        case live
        case reconnecting(attempt: Int, delay: Duration)
        case paused
        /// Stopped for good, e.g. the preview is no longer running.
        case ended(reason: String)
        case failed(message: String)
    }

    typealias RequestFactory = @Sendable () async throws -> URLRequest
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Failures before H.264 is given up for JPEG, as SimPortal's browser viewer does.
    static let decodeFailureLimit = 4
    /// A stalled writer must never accumulate seconds of taps or unbounded text.
    static let maximumPendingMessages = 64

    private(set) var state: State = .idle
    private(set) var device: SimulatorDeviceSummary?
    /// The stream's size in pixels; aspect-fit the screen view to it.
    private(set) var pixelSize: CGSize?
    private(set) var viewerCount = 0
    /// The codec in use. After repeated decode failures this becomes JPEG
    /// for the rest of this controller's life, reconnects included.
    private(set) var codec: SimulatorStreamCodec
    private(set) var quality: SimulatorStreamQuality
    /// The server's latest notice or error, for a transient message.
    private(set) var lastNotice: String?
    /// Frames handed to the display. Changes every frame: read it from a
    /// timer or `TimelineView`, not in a view body that should stay idle.
    private(set) var framesShown = 0
    private(set) var rttMilliseconds: Double?
    private(set) var lastAgentActivity: SimulatorAgentActivity?
    /// Whether keys typed now go to the simulator ("Typing goes to the simulator").
    private(set) var isTyping = false

    /// Input is only forwarded to a live, open stream.
    var acceptsInput: Bool { state == .live && connection?.isOpen == true }

    let renderer: SimulatorVideoRenderer

    /// The screen view currently showing this stream.
    @ObservationIgnored weak var inputSink: (any SimulatorStreamInputSink)?

    private let requestFactory: RequestFactory
    private let transportFactory: SimulatorStreamTransportFactory
    private let pingInterval: Duration
    private let openTimeout: Duration
    private let backoffSleep: Sleep
    private let clockOrigin = ContinuousClock.now

    private struct Connection {
        let transport: any SimulatorStreamTransport
        let outbox: AsyncStream<String>.Continuation
        var isOpen = false
    }

    private enum Outcome {
        case retry
        case stop(State)
    }

    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    /// Bumped by every start and stop, so a superseded loop can tell it is stale.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var decodeFailures = 0
    @ObservationIgnored private var lastPongAt: ContinuousClock.Instant?

    /// - Parameters:
    ///   - requestFactory: Makes the upgrade request (a `ws`/`wss` URL with
    ///     credentials already attached), fresh for every connection attempt.
    ///     Throw `SimulatorStreamStop` to stop instead of retrying.
    ///   - transportFactory: The socket; tests pass a fake.
    ///   - pingInterval: How often to measure round trips. Three intervals
    ///     without a pong count as a dead connection, even if video still arrives.
    ///   - backoffSleep: Waits between reconnects; tests make it instant.
    init(requestFactory: @escaping RequestFactory,
         transportFactory: @escaping SimulatorStreamTransportFactory = URLSessionSimulatorStreamTransport.factory,
         quality: SimulatorStreamQuality = .high,
         codec: SimulatorStreamCodec = .h264,
         pingInterval: Duration = .seconds(10),
         openTimeout: Duration = .seconds(20),
         backoffSleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.requestFactory = requestFactory
        self.transportFactory = transportFactory
        self.quality = quality
        self.codec = codec
        self.pingInterval = pingInterval
        self.openTimeout = openTimeout
        self.backoffSleep = backoffSleep
        renderer = SimulatorVideoRenderer()
        renderer.setCodec(codec)
        renderer.onEvent = { [weak self] event in self?.rendererDid(event) }
    }

    // MARK: Lifecycle

    func connect() {
        switch state {
        case .connecting, .waitingForDevice, .live, .reconnecting: return
        case .idle, .paused, .ended, .failed: start()
        }
    }

    func disconnect() {
        stop(becoming: .idle)
    }

    /// Reopens this exact preview without restarting the simulator or replaying input.
    func reconnect() {
        stop(becoming: .idle)
        lastNotice = nil
        start()
    }

    func dismissNotice() {
        lastNotice = nil
    }

    /// Closes the socket without any effect on the simulator; `resume()` reconnects.
    func pause() {
        switch state {
        case .connecting, .waitingForDevice, .live, .reconnecting: stop(becoming: .paused)
        case .idle, .paused, .ended, .failed: return
        }
    }

    func resume() {
        guard state == .paused else { return }
        start()
    }

    // MARK: Input and stream control

    /// Sends on the open socket, in order. Dropped while not connected: replaying
    /// input after a reconnect could repeat taps or typing.
    func send(_ message: SimulatorClientMessage) {
        guard let connection, connection.isOpen, message.isWithinRelayLimits else { return }
        guard !message.isInput || acceptsInput else { return }
        if case .dropped = connection.outbox.yield(message.json) {
            // Losing a touch/key release would leave held input on the server.
            // Closing releases it there; the fresh socket starts with no queued actions.
            reconnect()
            lastNotice = "The controls fell behind. Reconnecting to clear pending input."
        }
    }

    func pressButton(_ button: SimulatorHardwareButton) {
        send(.button(button))
    }

    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let message = SimulatorClientMessage.paste(text)
        guard message.isWithinRelayLimits else {
            lastNotice = "That's too much text to paste into the simulator at once."
            return
        }
        send(message)
    }

    func setQuality(_ quality: SimulatorStreamQuality) {
        guard quality != self.quality else { return }
        self.quality = quality
        send(.quality(quality))
    }

    func setTyping(_ typing: Bool) {
        if isTyping != typing { isTyping = typing }
    }

    // MARK: Connection loop

    private func start() {
        generation += 1
        let id = generation
        reconnectAttempt = 0
        setState(.connecting)
        connectionTask = Task { [weak self] in
            await self?.run(id: id)
        }
    }

    private func stop(becoming newState: State) {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        closeConnection()
        setState(newState)
    }

    private func isCurrent(_ id: Int) -> Bool {
        id == generation && !Task.isCancelled
    }

    private func run(id: Int) async {
        while isCurrent(id) {
            let outcome = await attempt(id: id)
            guard isCurrent(id) else { return }
            switch outcome {
            case .stop(let final):
                setState(final)
                connectionTask = nil
                return
            case .retry:
                reconnectAttempt += 1
                let delay = Self.backoff(forAttempt: reconnectAttempt)
                setState(.reconnecting(attempt: reconnectAttempt, delay: delay))
                do { try await backoffSleep(delay) } catch { return }
            }
        }
    }

    /// 0.5 s, doubling to 8 s.
    static func backoff(forAttempt attempt: Int) -> Duration {
        .milliseconds(500 << min(max(attempt - 1, 0), 4))
    }

    private func attempt(id: Int) async -> Outcome {
        let request: URLRequest
        do {
            request = try await requestFactory()
        } catch let stop as SimulatorStreamStop {
            switch stop {
            case .ended(let reason): return .stop(.ended(reason: reason))
            case .failed(let message): return .stop(.failed(message: message))
            }
        } catch {
            return .retry
        }
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            return .stop(.failed(message: "The simulator stream needs a ws:// or wss:// address"))
        }
        guard isCurrent(id) else { return .retry }

        let transport = transportFactory(request)
        let (outbox, continuation) = AsyncStream.makeStream(
            of: String.self, bufferingPolicy: .bufferingOldest(Self.maximumPendingMessages))
        connection = Connection(transport: transport, outbox: continuation)
        defer {
            if connection?.transport === transport { closeConnection() }
        }

        let openTimeout = openTimeout
        let watchdog = Task {
            try? await Task.sleep(for: openTimeout)
            guard !Task.isCancelled else { return }
            transport.close()
        }
        do {
            try await transport.open()
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            return outcome(for: error)
        }
        guard isCurrent(id), connection?.transport === transport else { return .retry }

        connection?.isOpen = true
        lastPongAt = .now
        rttMilliseconds = nil
        // SimPortal accepts hello at any time, so it goes first, right after the upgrade.
        send(.hello(codec: codec, quality: quality))
        send(.ping(t: elapsedMilliseconds()))

        return await withTaskGroup(of: Void.self, returning: Outcome.self) { group in
            group.addTask { [weak self] in await self?.pump(outbox, to: transport) }
            group.addTask { [weak self] in await self?.keepAlive(transport, id: id) }
            let outcome = await receive(from: transport, id: id)
            group.cancelAll()
            return outcome
        }
    }

    private func pump(_ outbox: AsyncStream<String>, to transport: any SimulatorStreamTransport) async {
        for await text in outbox {
            guard !Task.isCancelled, connection?.transport === transport else { return }
            do {
                try await transport.send(text)
            } catch {
                transport.close()
                return
            }
        }
    }

    private func keepAlive(_ transport: any SimulatorStreamTransport, id: Int) async {
        while isCurrent(id) {
            do { try await Task.sleep(for: pingInterval) } catch { return }
            guard isCurrent(id) else { return }
            if let lastPongAt, ContinuousClock.now - lastPongAt > pingInterval * 3 {
                // Video alone cannot prove that commands reach the server.
                lastNotice = "The controls stopped responding. Reconnecting…"
                transport.close()
                return
            }
            send(.ping(t: elapsedMilliseconds()))
        }
    }

    private func receive(from transport: any SimulatorStreamTransport, id: Int) async -> Outcome {
        do {
            while true {
                let frame = try await transport.receive()
                guard isCurrent(id) else { return .retry }
                switch frame {
                case .text(let text): handleText(text)
                case .binary(let data): handleBinary(data)
                }
            }
        } catch {
            return outcome(for: error)
        }
    }

    private func outcome(for error: any Error) -> Outcome {
        switch error as? SimulatorStreamTransportError {
        case .handshakeRejected(let status)?:
            switch status {
            case 401, 403: return .stop(.ended(reason: "The companion rejected the stream credentials"))
            case 404, 409, 410: return .stop(.ended(reason: "This preview is no longer running"))
            default: return .retry
            }
        case .closed(let code)? where code == 4004:
            // SimPortal could not find the simulator.
            return .stop(.ended(reason: "This preview is no longer running"))
        default:
            return .retry
        }
    }

    private func closeConnection() {
        guard let connection else { return }
        self.connection = nil
        connection.outbox.finish()
        connection.transport.close()
        renderer.resetStream()
        inputSink?.streamDidReleaseInput()
    }

    // MARK: Messages

    private func handleText(_ text: String) {
        guard let message = SimulatorServerMessage(text: text) else { return }
        switch message {
        case .device(let device):
            self.device = device
        case .ready(let width, let height, let serverCodec):
            setPixelSize(CGSize(width: width, height: height))
            if let serverCodec, serverCodec != codec { adopt(serverCodec) }
            setState(.live)
        case .state(let simulatorState):
            setState(.waitingForDevice(state: simulatorState))
        case .surface(let width, let height):
            setPixelSize(CGSize(width: width, height: height))
        case .viewers(let count):
            if viewerCount != count { viewerCount = count }
        case .pong(let t):
            let rtt = elapsedMilliseconds() - t
            if rtt >= 0, rtt < 60_000 {
                lastPongAt = .now
                rttMilliseconds = rtt
            }
        case .activity(let action):
            lastAgentActivity = SimulatorAgentActivity(action: action, receivedAt: .now)
        case .notice(_, let message), .error(let message):
            lastNotice = message
        case .ended(let reason):
            // The server released this viewer's input; it re-attaches by itself.
            renderer.resetStream()
            inputSink?.streamDidReleaseInput()
            setState(.waitingForDevice(state: reason == "simulator shut down" ? "Shutdown" : "Restarting"))
        }
    }

    private func handleBinary(_ data: Data) {
        let message: SimulatorBinaryMessage?
        do {
            message = try SimulatorBinaryMessage.parse(data)
        } catch {
            // A lost H.264 frame breaks the chain of frames after it.
            if data.first == 0x03 { renderer.frameDropped() }
            return
        }
        switch message {
        case .h264Config(let config)?:
            guard codec == .h264 else { return }
            setPixelSize(CGSize(width: config.width, height: config.height))
            renderer.configure(config)
        case .h264Frame(let frame)?:
            renderer.enqueue(frame)
        case .jpeg(let frame)?:
            guard codec == .jpeg else { return }
            setPixelSize(CGSize(width: frame.width, height: frame.height))
            renderer.showJPEG(frame)
        case nil:
            return
        }
    }

    private func rendererDid(_ event: SimulatorVideoRenderer.Event) {
        switch event {
        case .frameShown:
            framesShown += 1
            reconnectAttempt = 0
            if connection?.isOpen == true { setState(.live) }
        case .needsKeyframe:
            send(.keyframe)
        case .decodeFailed:
            guard codec == .h264 else { return }
            decodeFailures += 1
            if decodeFailures >= Self.decodeFailureLimit {
                adopt(.jpeg)
                lastNotice = "Video decoding failed here, so the stream switched to JPEG."
                send(.hello(codec: .jpeg, quality: quality))
            } else {
                send(.keyframe)
            }
        }
    }

    private func adopt(_ codec: SimulatorStreamCodec) {
        self.codec = codec
        renderer.setCodec(codec)
    }

    private func setState(_ newState: State) {
        if state != newState { state = newState }
    }

    private func setPixelSize(_ size: CGSize) {
        guard size != pixelSize else { return }
        pixelSize = size
        renderer.contentPixelSize = size
    }

    private func elapsedMilliseconds() -> Double {
        let elapsed = ContinuousClock.now - clockOrigin
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
