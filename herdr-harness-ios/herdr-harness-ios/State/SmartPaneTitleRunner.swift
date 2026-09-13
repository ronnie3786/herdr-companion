import Foundation

@MainActor
protocol SmartPaneTitleRunning {
    func response(for pane: HerdrPane, model: HerdrAppModel) async throws -> String
}

/// Reads the existing conversation, then names it in a separate read-only run.
/// Never submits a prompt to the user's live chat.
struct SmartPaneTitleRunner: SmartPaneTitleRunning {
    func response(for pane: HerdrPane, model: HerdrAppModel) async throws -> String {
        let snapshot = try await model.fetchPiConversationSnapshot(for: pane)
        let context = SmartPaneTitle.context(from: snapshot)
        guard snapshot.available, !context.isEmpty else {
            throw SmartPaneTitleError.failed("This Pi session has no readable conversation to name yet.")
        }
        let controller = HeadlessAgentController()
        await controller.submit(
            prompt: SmartPaneTitle.prompt(context: context),
            machineID: pane.machineID,
            mode: .ask,
            agentModel: model.agentModel.isEmpty ? nil : model.agentModel,
            thinkingLevel: "low",
            model: model
        )
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while controller.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw SmartPaneTitleError.failed("Naming took too long. Try again.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard let run = controller.run, run.status == .completed else {
                throw SmartPaneTitleError.failed(
                    controller.errorMessage ?? controller.run?.error ?? "The naming run did not complete."
                )
            }
            let response = run.response ?? ""
            await controller.discard(model: model)
            return response
        } catch {
            // Cleanup must still run when the caller has been cancelled.
            await Task { @MainActor in await controller.close(model: model) }.value
            throw error
        }
    }
}

enum SmartPaneTitleError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}
