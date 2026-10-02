import Foundation
import Observation

@MainActor
@Observable
final class ChatSkimCoordinator {
    let id = UUID()
    private(set) var values: [String: FirstMateSkim] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var capabilitiesTask: Task<ChatSkimCapabilities?, Never>?
    @ObservationIgnored private var lanes: [Task<Void, Never>?] = [nil, nil]
    @ObservationIgnored private var nextLane = 0
    private let pollInterval: Duration
    private let pollLimit: Int

    init(pollInterval: Duration = .seconds(2), pollLimit: Int = 60) {
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
    }

    func load(_ source: ChatSkimSource, transport: ChatSkimTransport) async {
        if let task = tasks[source.id] { await task.value; return }
        guard values[source.id] == nil else { return }
        // Two ordered lanes bound requests without a timer per waiting row.
        // Large histories can wait without repeatedly waking the main actor.
        let lane = nextLane
        nextLane = (nextLane + 1) % lanes.count
        let previous = lanes[lane]
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await fetch(source, transport: transport)
        }
        lanes[lane] = task
        tasks[source.id] = task
        await task.value
        tasks[source.id] = nil
    }

    private func fetch(_ source: ChatSkimSource, transport: ChatSkimTransport) async {
        if capabilitiesTask == nil {
            capabilitiesTask = Task { try? await transport.capabilities() }
        }
        guard let capability = await capabilitiesTask?.value else {
            capabilitiesTask = nil
            return
        }
        guard capability.enabled,
              source.reply.split(whereSeparator: \.isWhitespace).count >= capability.minWords,
              source.reply.count <= 131_072 else { return }
        do {
            try Task.checkCancellation()
            var envelope = try await transport.request(source.reply, source.question)
            values[source.id] = envelope.skim
            // Bounded even if a companion loses its job or connection.
            for _ in 0..<pollLimit {
                guard envelope.skim?.status == .pending, let id = envelope.id else { return }
                try await Task.sleep(for: pollInterval)
                envelope = try await transport.fetch(id)
                values[source.id] = envelope.skim
            }
            values[source.id] = FirstMateSkim(status: .failed)
        } catch is CancellationError {
            values[source.id] = nil
        } catch {
            values[source.id] = Task.isCancelled ? nil : FirstMateSkim(status: .failed)
        }
    }

    func cancel() {
        for task in tasks.values { task.cancel() }
        capabilitiesTask?.cancel()
    }
}
