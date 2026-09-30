import Foundation
import Synchronization

/// One message off the viewer socket.
enum SimulatorStreamFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

enum SimulatorStreamTransportError: Error, Equatable, Sendable {
    /// The upgrade was answered with this HTTP status instead of 101.
    case handshakeRejected(status: Int)
    /// The server closed the socket with this WebSocket close code (SimPortal
    /// uses 4004 for a simulator it cannot find).
    case closed(code: Int)
    /// `close()` was called.
    case cancelled
    /// Anything else: DNS, TLS, a reset connection, a timeout.
    case failed(String)
}

/// The viewer socket, abstracted so the controller can be tested without a
/// listening socket (the app's sandbox allows client connections only).
protocol SimulatorStreamTransport: AnyObject, Sendable {
    /// Completes once the WebSocket upgrade succeeds.
    func open() async throws
    func send(_ text: String) async throws
    func receive() async throws -> SimulatorStreamFrame
    /// Idempotent; pending calls fail with `SimulatorStreamTransportError.cancelled`.
    func close()
}

typealias SimulatorStreamTransportFactory = @Sendable (URLRequest) -> any SimulatorStreamTransport

/// `URLSessionWebSocketTask` with a session of its own, so the delegate can
/// report the upgrade's HTTP status and every connection is torn down whole.
final class URLSessionSimulatorStreamTransport: NSObject, SimulatorStreamTransport, URLSessionWebSocketDelegate {
    /// Keyframes exceed URLSession's 1 MiB default.
    static let maximumMessageSize = 32 * 1024 * 1024

    static let factory: SimulatorStreamTransportFactory = { URLSessionSimulatorStreamTransport(request: $0) }

    private struct State {
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var openContinuation: CheckedContinuation<Void, any Error>?
        var isOpen = false
        var isClosed = false
    }

    private let request: URLRequest
    private let state = Mutex(State())

    init(request: URLRequest) {
        self.request = request
    }

    func open() async throws {
        // Ephemeral: nothing about the stream or its credentials is cached.
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let started = state.withLock { state -> Bool in
                guard !state.isClosed else { return false }
                state.session = session
                state.task = task
                state.openContinuation = continuation
                return true
            }
            guard started else {
                session.invalidateAndCancel()
                continuation.resume(throwing: SimulatorStreamTransportError.cancelled)
                return
            }
            task.resume()
        }
    }

    func send(_ text: String) async throws {
        let task = try openTask()
        do {
            try await task.send(.string(text))
        } catch {
            throw failure(for: task, error: error)
        }
    }

    func receive() async throws -> SimulatorStreamFrame {
        let task = try openTask()
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw failure(for: task, error: error)
        }
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw SimulatorStreamTransportError.failed("Unsupported WebSocket message")
        }
    }

    func close() {
        let (session, task, continuation) = state.withLock { state in
            state.isClosed = true
            defer {
                state.openContinuation = nil
                state.session = nil
                state.task = nil
            }
            return (state.session, state.task, state.openContinuation)
        }
        continuation?.resume(throwing: SimulatorStreamTransportError.cancelled)
        task?.cancel(with: .normalClosure, reason: nil)
        // Releases the session's strong reference to its delegate (self).
        session?.invalidateAndCancel()
    }

    private func openTask() throws -> URLSessionWebSocketTask {
        let task = state.withLock { $0.isOpen && !$0.isClosed ? $0.task : nil }
        guard let task else { throw SimulatorStreamTransportError.cancelled }
        return task
    }

    private func failure(for task: URLSessionWebSocketTask, error: any Error) -> SimulatorStreamTransportError {
        if state.withLock({ $0.isClosed }) { return .cancelled }
        if task.closeCode != .invalid { return .closed(code: task.closeCode.rawValue) }
        return .failed(error.localizedDescription)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let continuation = state.withLock { state in
            state.isOpen = true
            defer { state.openContinuation = nil }
            return state.openContinuation
        }
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = state.withLock { state in
            defer { state.openContinuation = nil }
            return state.openContinuation
        }
        guard let continuation else { return }
        // Only a failed upgrade gets here with the open still pending.
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            continuation.resume(throwing: SimulatorStreamTransportError.handshakeRejected(status: response.statusCode))
        } else {
            continuation.resume(throwing: SimulatorStreamTransportError.failed(error?.localizedDescription ?? "The connection closed"))
        }
    }
}
