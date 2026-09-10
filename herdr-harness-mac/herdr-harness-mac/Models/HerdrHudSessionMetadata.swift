import Foundation

struct HerdrHudSessionMetadata: Equatable {
    var modelName: String?
    var cost: String?

    init(modelName: String? = nil, cost: String? = nil) {
        self.modelName = modelName
        self.cost = cost
    }

    init(state: PiJSONValue?) {
        modelName = PiModelIdentity(json: state?["model"])?.displayName
        cost = PiSessionCost(from: state?["cost"])?.summary
    }

    var accessibilitySummary: String {
        [modelName.map { "model \($0)" }, cost.map { "session cost \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    func label(showsModel: Bool) -> String? {
        guard modelName != nil || cost != nil else { return nil }
        // Never show the opposite label type while the rest of the stack is
        // in this phase, even when this session has only one reported value.
        return showsModel ? modelName ?? "Model …" : cost ?? "Cost …"
    }
}
