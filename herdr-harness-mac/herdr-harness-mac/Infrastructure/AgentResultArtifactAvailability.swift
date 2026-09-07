import Foundation

struct ResultArtifactOpenFailure: Identifiable, Equatable, Sendable {
    let artifact: AgentResultArtifact
    let title: String
    let message: String
    let allowsBrowserFallback: Bool

    var id: String { artifact.id }

    init(artifact: AgentResultArtifact, error: any Error) {
        self.artifact = artifact
        let normalized = AgentResultArtifactAvailabilityError.normalized(error)
        let availability = normalized as? AgentResultArtifactAvailabilityError
        title = availability?.alertTitle ?? "Couldn’t open document"
        message = availability?.message(for: artifact.kind) ?? normalized.localizedDescription
        allowsBrowserFallback = artifact.kind == .link && availability?.allowsBrowserFallback == true
    }
}

enum AgentResultArtifactAvailabilityError: LocalizedError, Equatable, Sendable {
    case notFound
    case accessDenied
    case offline
    case timedOut
    case serverUnavailable
    case connectionFailed

    var alertTitle: String {
        switch self {
        case .notFound: "Document unavailable"
        case .accessDenied: "Document access needed"
        case .offline: "You’re offline"
        case .timedOut: "Document request timed out"
        case .serverUnavailable: "Document server unavailable"
        case .connectionFailed: "Couldn’t reach this document"
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound: "This document could not be found. It may have been moved or deleted."
        case .accessDenied: "Herdr doesn’t have access to this document. Check its permissions and try again."
        case .offline: "Herdr has no connection to the document’s source. Reconnect and try again."
        case .timedOut: "The document’s source took too long to respond. Try again in a moment."
        case .serverUnavailable: "The document’s source is temporarily unavailable. Try again later."
        case .connectionFailed: "Herdr couldn’t connect to the document’s source. Check your connection and try again."
        }
    }

    func message(for kind: AgentResultArtifact.Kind) -> String {
        let message = errorDescription ?? alertTitle
        if self == .notFound, kind == .link {
            return message + " If this link requires sign-in, try opening it in your browser."
        }
        return message
    }

    var allowsBrowserFallback: Bool { self == .notFound || self == .accessDenied }

    static func fromHTTPStatus(_ status: Int) -> Self? {
        switch status {
        case 404, 410: .notFound
        case 401, 403: .accessDenied
        case 408, 504: .timedOut
        case 429, 500...599: .serverUnavailable
        default: nil
        }
    }

    static func normalized(_ error: any Error) -> any Error {
        if error is Self || error is CancellationError { return error }
        if let apiError = error as? APIError {
            switch apiError {
            case let .server(status, _): return fromHTTPStatus(status) ?? error
            case .noActiveConnection: return Self.offline
            default: return error
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .fileDoesNotExist: return Self.notFound
            case .noPermissionsToReadFile, .userAuthenticationRequired: return Self.accessDenied
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return Self.offline
            case .timedOut: return Self.timedOut
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed: return Self.connectionFailed
            default: return error
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile: return Self.notFound
            case .fileReadNoPermission: return Self.accessDenied
            default: return error
            }
        }
        return error
    }
}

/// A small, anonymous availability check. Browser-owned authentication stays
/// in the browser; no Herdr bearer token or cookies are sent to a result URL.
struct AgentResultArtifactLinkChecker: Sendable {
    typealias Probe = @Sendable (URLRequest) async throws -> HTTPURLResponse
    private let probe: Probe

    init(probe: @escaping Probe = { try await ArtifactHTTPHeaderProbe.response(for: $0) }) {
        self.probe = probe
    }

    func check(_ url: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "HEAD"
        do {
            var response = try await probe(request)
            // Some document services reject HEAD even when GET works. Confirm
            // a missing response with GET, cancelling as soon as headers arrive.
            if [404, 405, 501].contains(response.statusCode) {
                request.httpMethod = "GET"
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                response = try await probe(request)
            }
            // A browser may hold cookies or credentials this probe cannot use.
            if [401, 403].contains(response.statusCode) { return }
            if let error = AgentResultArtifactAvailabilityError.fromHTTPStatus(response.statusCode) { throw error }
            try Task.checkCancellation()
        } catch {
            throw AgentResultArtifactAvailabilityError.normalized(error)
        }
    }
}

/// Reads status headers only, including when a server ignores Range. The
/// bounded probe never downloads a document merely to decide whether to open it.
private final class ArtifactHTTPHeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, any Error>?
    private var session: URLSession?
    private var cancelled = false

    static func response(for request: URLRequest) async throws -> HTTPURLResponse {
        let probe = ArtifactHTTPHeaderProbe()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { probe.start(request, continuation: $0) }
        } onCancel: {
            probe.cancel()
        }
    }

    private func start(_ request: URLRequest, continuation: CheckedContinuation<HTTPURLResponse, any Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<HTTPURLResponse, any Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        if let response = response as? HTTPURLResponse { finish(.success(response)) }
        else { finish(.failure(APIError.invalidResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
    }
}
