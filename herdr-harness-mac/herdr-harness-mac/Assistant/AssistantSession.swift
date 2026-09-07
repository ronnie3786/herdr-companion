import Foundation
import Observation

@MainActor @Observable
final class AssistantSession {
    let title: String
    let machineID: String
    let paneID: String?
    let rootPath: String?
    var context: AssistantContext
    var currentContext: AssistantContext
    var draft = ""
    var selectedModel = ""
    private(set) var turns: [HeadlessAgentRun] = []
    private(set) var models: [PiAvailableModel] = []
    private(set) var isRunning = false
    private(set) var isReady = false
    private(set) var error: String?
    private(set) var pending: AssistantRequest?
    private(set) var isPromoting = false
    @ObservationIgnored private let transport: AssistantTransport
    @ObservationIgnored private let persistence: AssistantPersistence
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var isPreparing = false

    init(title: String, machineID: String, paneID: String?, rootPath: String?, context: AssistantContext,
         transport: AssistantTransport, persistence: AssistantPersistence) {
        self.title = title
        self.machineID = machineID
        self.paneID = paneID
        self.rootPath = rootPath
        self.context = context
        self.currentContext = context
        self.transport = transport
        self.persistence = persistence
    }

    var latest: HeadlessAgentRun? { turns.last }
    var canSend: Bool { isReady && !isRunning && !isPromoting && pending == nil && latest?.status != .promoted && latest?.status.isTerminal != false }

    func prepare() async {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        if let saved = await persistence.load() {
            context = saved.context
            draft = saved.draft
            turns = saved.turns
            pending = saved.pending
            selectedModel = saved.selectedModel
        }
        do {
            let capabilities = try await transport.capabilities()
            guard capabilities.profiles.contains("contextual-question-v1") else {
                error = "Update this machine's companion server to use contextual questions."
                return
            }
            isReady = true
            if let catalog = try? await transport.models() { models = catalog.models }
            if let latest, !latest.status.isTerminal {
                isRunning = true
                operation = Task { await observe(latest.id) }
            }
        } catch { self.error = "Contextual questions are unavailable: \(error.localizedDescription)" }
    }

    func submit() {
        guard canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pending = AssistantRequest(prompt: draft, paneId: paneID, scope: .init(expectedRootPath: rootPath),
                                   context: context, continueFromRunId: latest?.id,
                                   model: selectedModel.isEmpty ? nil : selectedModel)
        retrySubmission()
    }

    func retrySubmission() {
        guard let request = pending, !isRunning else { return }
        isRunning = true
        stopRequested = false
        error = nil
        operation = Task {
            guard await save() else { isRunning = false; return }
            do {
                let run = try await transport.start(request)
                update(run)
                pending = nil
                if draft == request.prompt { draft = "" }
                _ = await save()
                if stopRequested { try await cancelAccepted(run.id) }
                await observe(run.id)
            } catch {
                if case let APIError.server(status, _) = error, [400, 403, 404, 409, 413, 422].contains(status) {
                    pending = nil
                    self.error = error.localizedDescription
                } else {
                    self.error = error.localizedDescription + " Reconcile submission to check whether it was accepted."
                }
                isRunning = false
                _ = await save()
            }
        }
    }

    private func observe(_ id: String) async {
        defer { isRunning = false }
        var failures = 0
        while !Task.isCancelled {
            do {
                let run = try await transport.fetch(id)
                update(run)
                error = nil
                failures = 0
                _ = await save()
                if run.status.isTerminal { return }
            } catch {
                self.error = "Reconnecting to the original machine: \(error.localizedDescription)"
                failures += 1
                if failures >= 10 { return }
            }
            try? await Task.sleep(for: .seconds(failures == 0 ? 1 : 3))
        }
    }

    func reconnect() {
        guard !isRunning, let latest, !latest.status.isTerminal else { return }
        isRunning = true
        operation = Task { await observe(latest.id) }
    }

    func stop() {
        stopRequested = true
        guard pending == nil, let latest, !latest.status.isTerminal else { return }
        Task {
            do { try await cancelAccepted(latest.id) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func cancelAccepted(_ id: String) async throws {
        update(try await transport.stop(id))
        _ = await save()
    }

    func promote() {
        guard let latest, latest.status == .completed, !isRunning, !isPromoting else { return }
        isPromoting = true
        Task {
            defer { isPromoting = false }
            do {
                let result = try await transport.promote(latest.id)
                update(result)
                _ = await save()
                if let pane = result.promotedPaneID { transport.openAgent(pane) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func openAgent() {
        if let pane = latest?.promotedPaneID { transport.openAgent(pane) }
    }

    func newQuestion() {
        guard !isRunning, !isPromoting, pending == nil, latest?.status.isTerminal != false else { return }
        turns = []
        error = nil
        draft = ""
        Task { _ = await save() }
    }

    func refreshContext() {
        guard canSend else { return }
        context = currentContext
        context.snapshotId = UUID().uuidString
        context.capturedAt = Date.now.ISO8601Format()
        Task { _ = await save() }
    }

    func addContext(_ text: String) {
        guard canSend else { return }
        guard text.utf8.count <= 16 * 1024, context.items.count < 16 else {
            error = "Attach at most 16 items, each smaller than 16 KiB."
            return
        }
        context.items.append(.init(id: UUID().uuidString, kind: "text.v1", label: "Added context", text: text))
        context.snapshotId = UUID().uuidString
        context.capturedAt = Date.now.ISO8601Format()
        Task { _ = await save() }
    }

    func removeContext(_ id: String) {
        guard canSend else { return }
        context.items.removeAll { $0.id == id }
        context.snapshotId = UUID().uuidString
        context.capturedAt = Date.now.ISO8601Format()
        Task { _ = await save() }
    }

    func saveDraft() { Task { _ = await save() } }

    @discardableResult private func save() async -> Bool {
        do {
            try await persistence.save(.init(context: context, draft: draft, turns: turns, pending: pending, selectedModel: selectedModel))
            return true
        } catch {
            self.error = "Could not save this question: \(error.localizedDescription)"
            return false
        }
    }

    private func update(_ run: HeadlessAgentRun) {
        if let index = turns.firstIndex(where: { $0.id == run.id }) { turns[index] = run }
        else { turns.append(run) }
    }
}
