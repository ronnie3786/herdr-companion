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

    var alternates: Bool { modelName != nil && cost != nil }
    var accessibilitySummary: String {
        [modelName.map { "model \($0)" }, cost.map { "session cost \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    func label(showsModel: Bool) -> String? {
        showsModel ? modelName ?? cost : cost ?? modelName
    }
}
