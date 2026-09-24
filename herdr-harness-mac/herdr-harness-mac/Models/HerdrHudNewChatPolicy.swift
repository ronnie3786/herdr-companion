import Foundation

/// Host evidence that identifies this Mac among Herdr's configured machines.
/// The values are injected so callers and tests never depend on roster order,
/// display names, or role labels.
struct HerdrHudHostIdentity: Equatable, Sendable {
    let hostNames: [String]
    let addresses: [String]

    init(hostNames: [String] = [], addresses: [String] = []) {
        self.hostNames = hostNames
        self.addresses = addresses
    }

    /// The current process's host names and interface addresses. This is
    /// evidence only: identification still requires a unique roster match.
    static func current() -> HerdrHudHostIdentity {
        let host = Host.current()
        return HerdrHudHostIdentity(hostNames: host.names, addresses: host.addresses)
    }
}

/// How a fresh HUD composer chose its model. `.machineDefault` is the
/// automatic selection and deliberately carries no identity: it must be
/// resolved from the execution companion's own declared default. `.explicit`
/// is a per-draft override and can never be mistaken for an automatic default
/// when a request carries both across an async boundary.
enum HerdrHudModelChoice: Equatable, Sendable {
    case machineDefault
    case explicit(PiModelIdentity)

    var explicitIdentity: PiModelIdentity? {
        guard case let .explicit(identity) = self else { return nil }
        return identity
    }

    var isExplicit: Bool { explicitIdentity != nil }
}

/// A model catalog tagged with the exact companion that produced it. Pairing
/// makes a delayed response identifiable instead of letting it silently become
/// another machine's default.
struct HerdrHudMachineModelCatalog: Equatable, Sendable {
    let machineID: String
    let isAvailable: Bool
    let models: [PiAvailableModel]
    let defaultModel: PiModelIdentity?

    init(
        machineID: String,
        isAvailable: Bool,
        models: [PiAvailableModel],
        defaultModel: PiModelIdentity?
    ) {
        self.machineID = machineID
        self.isAvailable = isAvailable
        self.models = models
        self.defaultModel = defaultModel
    }

    init(machineID: String, response: AgentModelCatalogResponse) {
        self.init(
            machineID: machineID,
            isAvailable: response.ok,
            models: response.models,
            defaultModel: response.defaultModel
        )
    }
}

enum HerdrHudNewChatPolicyError: LocalizedError, Equatable, Sendable {
    case catalogUnavailable
    case staleCatalog
    case missingDefaultModel
    case unavailableDefaultModel(PiModelIdentity)
    case unavailableModel(PiModelIdentity)
    case invalidModel

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable:
            "This Mac's model catalog is unavailable. Reconnect and try again."
        case .staleCatalog:
            "The model catalog belonged to another machine. Reload this machine's models before sending."
        case .missingDefaultModel:
            "This machine doesn't declare a default model. Choose a model for this chat."
        case let .unavailableDefaultModel(model):
            "This machine's default model (\(model.displayName)) isn't offered by its catalog. Choose a compatible model."
        case let .unavailableModel(model):
            "\(model.displayName) isn't offered by this machine's catalog. Choose another model."
        case .invalidModel:
            "The selected model is incomplete. Choose a model for this chat."
        }
    }
}

/// Pure routing rules for a genuinely fresh HUD composer: which configured
/// machine is this Mac, and which exact model the execution companion declares
/// as its default. Nothing here falls back to roster order, a previous
/// selection, or another machine's catalog.
struct HerdrHudNewChatPolicy: Equatable, Sendable {
    let hostIdentity: HerdrHudHostIdentity

    init(hostIdentity: HerdrHudHostIdentity) {
        self.hostIdentity = hostIdentity
    }

    init(hostNames: [String] = [], addresses: [String] = []) {
        hostIdentity = HerdrHudHostIdentity(hostNames: hostNames, addresses: addresses)
    }

    /// The unique configured machine that is this Mac, or nil when the roster
    /// has no unique loopback/host/address evidence. Ambiguity requires an
    /// explicit machine selection in the composer instead of a silent guess.
    func localMachine(in machines: [HerdrMachine]) -> HerdrMachine? {
        HerdrNotesSource.localMachine(
            in: machines,
            hostNames: hostIdentity.hostNames,
            addresses: hostIdentity.addresses
        )
    }

    /// Resolves the exact declared default for the execution companion. A
    /// missing, stale, or unreadable catalog and a missing or unavailable
    /// default are actionable errors, never another model.
    @discardableResult
    func resolveDefaultModel(
        for machineID: String,
        catalog: HerdrHudMachineModelCatalog?
    ) throws -> PiModelIdentity {
        guard let catalog else { throw HerdrHudNewChatPolicyError.catalogUnavailable }
        guard catalog.machineID == machineID else { throw HerdrHudNewChatPolicyError.staleCatalog }
        guard catalog.isAvailable else { throw HerdrHudNewChatPolicyError.catalogUnavailable }
        guard let declared = catalog.defaultModel, Self.isComplete(declared) else {
            throw HerdrHudNewChatPolicyError.missingDefaultModel
        }
        if !catalog.models.isEmpty,
           !catalog.models.contains(where: { $0.id == declared.fullID }) {
            throw HerdrHudNewChatPolicyError.unavailableDefaultModel(declared)
        }
        return declared
    }

    /// Resolves the exact model for one submission. `.machineDefault` always
    /// comes from the execution companion's catalog; an explicit override is
    /// preserved and validated against that same catalog when one is present.
    @discardableResult
    func resolve(
        _ choice: HerdrHudModelChoice,
        for machineID: String,
        catalog: HerdrHudMachineModelCatalog?
    ) throws -> PiModelIdentity {
        switch choice {
        case .machineDefault:
            return try resolveDefaultModel(for: machineID, catalog: catalog)
        case let .explicit(identity):
            guard Self.isComplete(identity) else { throw HerdrHudNewChatPolicyError.invalidModel }
            if let catalog {
                guard catalog.machineID == machineID else { throw HerdrHudNewChatPolicyError.staleCatalog }
                guard catalog.isAvailable else { throw HerdrHudNewChatPolicyError.catalogUnavailable }
                if !catalog.models.isEmpty,
                   !catalog.models.contains(where: { $0.id == identity.fullID }) {
                    throw HerdrHudNewChatPolicyError.unavailableModel(identity)
                }
            }
            return identity
        }
    }

    static func isComplete(_ identity: PiModelIdentity) -> Bool {
        isCompletePart(identity.provider) && isCompletePart(identity.id)
    }

    static func isCompletePart(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
