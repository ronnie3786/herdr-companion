import Foundation

/// The model and effort a Smart Rename ask should use, plus the companion the
/// selection was validated against. `modelID == nil` means omit `model` and let
/// the execution machine's Pi installation pick its configured default. The
/// optional notice remains for callers that display one; an unavailable
/// selection now fails before dispatch instead of being substituted.
struct SmartRenameModelResolution: Equatable, Sendable {
    let modelID: String?
    let thinkingLevel: PiThinkingLevel
    let machineName: String
    let notice: String?
}

/// Naming resolves against one exact machine's catalog. These failures are
/// actionable and must stop the rename before any request is dispatched; the
/// pane keeps its current title.
enum SmartRenameModelRoutingError: LocalizedError, Equatable {
    /// The companion did not return a usable catalog (transport, auth, or
    /// `ok: false`).
    case catalogUnavailable(machineName: String)
    /// The catalog decoded but advertised no models at all.
    case catalogEmpty(machineName: String)
    /// The machine declares a default model that is not in its own catalog.
    case defaultModelUnavailable(machineName: String, model: String)
    /// An explicit or inherited Smart Rename selection the execution machine
    /// does not offer. Never replaced with another model or machine.
    case modelUnavailable(machineName: String, model: String)
    /// A known non-reasoning model paired with an effort above Off.
    case thinkingLevelUnsupported(machineName: String, model: String, level: PiThinkingLevel)

    var errorDescription: String? {
        switch self {
        case let .catalogUnavailable(machineName):
            "Couldn't read the models available on \(machineName). Check that its companion is connected, then try Smart Rename again."
        case let .catalogEmpty(machineName):
            "\(machineName)'s Pi installation reported no available models. Configure a provider there, then try Smart Rename again."
        case let .defaultModelUnavailable(machineName, model):
            "\(machineName)'s default model \(model) is missing from its available model list. Update the Pi default there or choose a Smart Rename model in Settings."
        case let .modelUnavailable(machineName, model):
            "The Smart Rename model \(model) isn't offered by \(machineName). Choose an available model in Settings or configure that provider on \(machineName)."
        case let .thinkingLevelUnsupported(machineName, model, level):
            "\(model) on \(machineName) can't use \(level.displayName) thinking. Choose Off for Smart Rename or select a reasoning-capable model in Settings."
        }
    }
}

/// A dispatched naming run that did not produce a usable title. The message
/// names the exact selection and the companion that executed it so the user can
/// correct Settings or that machine's provider configuration.
struct SmartRenameExecutionError: LocalizedError, Equatable, Sendable {
    let machineName: String
    let model: String
    let thinkingLevel: PiThinkingLevel
    let reason: String

    var errorDescription: String? {
        "Smart Rename couldn't run \(model) with \(thinkingLevel.displayName) thinking on \(machineName): \(reason) Check the Smart Rename model and provider configuration in Settings for \(machineName), then try again."
    }
}

/// Smart Rename keeps its own model/effort policy instead of the general
/// `AgentModelResolver`: naming must know the execution machine's declared
/// default, must surface an unavailable preference without rewriting it, and
/// must reject known-incompatible effort. Provider probing, credential
/// inspection, arbitrary retries, and cross-machine execution fallback are
/// intentionally out of scope.
enum SmartRenameModelRouting {
    /// Pure catalog seam. `preference` is the effective naming preference after
    /// inheritance (nil or blank means "the machine's default"). A non-blank
    /// preference missing from the execution machine's catalog is an error, not
    /// a fallback. The stored preference is never mutated here; callers retain
    /// it and only the request's model changes.
    static func resolveCatalog(
        preference: String?,
        thinkingLevel: PiThinkingLevel,
        catalog: AgentModelCatalogResponse,
        machineName: String
    ) throws -> SmartRenameModelResolution {
        guard catalog.ok else {
            throw SmartRenameModelRoutingError.catalogUnavailable(machineName: machineName)
        }
        guard !catalog.models.isEmpty else {
            throw SmartRenameModelRoutingError.catalogEmpty(machineName: machineName)
        }

        let wanted = preference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !wanted.isEmpty {
            guard let offered = catalog.models.first(where: { $0.id == wanted }) else {
                throw SmartRenameModelRoutingError.modelUnavailable(
                    machineName: machineName,
                    model: wanted
                )
            }
            return SmartRenameModelResolution(
                modelID: offered.id,
                thinkingLevel: try effort(thinkingLevel, for: offered, machineName: machineName),
                machineName: machineName,
                notice: nil
            )
        }

        // No effective naming preference: the companion's declared default, or
        // nothing at all so the execution machine's Pi default wins.
        let fallback = try machineDefault(
            catalog: catalog,
            models: catalog.models,
            machineName: machineName
        )
        return SmartRenameModelResolution(
            modelID: fallback.model?.id,
            thinkingLevel: try effort(thinkingLevel, for: fallback.model, machineName: machineName),
            machineName: machineName,
            notice: nil
        )
    }

    /// Fetches the catalog from `executionMachineID` itself — never the
    /// primary machine or a cached list — and resolves the saved settings
    /// against it. Throws without any dispatch when the catalog is unusable.
    @MainActor
    static func resolve(
        settings: AgentModelSettings,
        executionMachineID: String,
        appModel: HerdrAppModel
    ) async throws -> SmartRenameModelResolution {
        let machineName = machineName(for: executionMachineID, in: appModel)
        let catalog: AgentModelCatalogResponse
        do {
            catalog = try await appModel.fetchAgentModels(machineID: executionMachineID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SmartRenameModelRoutingError.catalogUnavailable(machineName: machineName)
        }
        return try resolveCatalog(
            preference: settings.effectiveSmartRenameModel,
            thinkingLevel: settings.smartRenameThinkingLevel,
            catalog: catalog,
            machineName: machineName
        )
    }

    /// The display name the execution companion is known by, with its ID as the
    /// fallback so failures always identify a destination.
    @MainActor
    static func machineName(for machineID: String, in appModel: HerdrAppModel) -> String {
        appModel.machines.first { $0.id == machineID }?.name ?? machineID
    }

    /// Wraps a dispatched naming-run failure with the exact selection and
    /// execution companion. Cancellation passes through unchanged, and no
    /// replacement model or machine is ever attempted here.
    static func executionError(_ error: Error, resolution: SmartRenameModelResolution) -> Error {
        if error is CancellationError { return error }
        if let noteError = error as? HerdrNoteAIError, case .cancelled = noteError { return error }
        return SmartRenameExecutionError(
            machineName: resolution.machineName,
            model: resolution.modelID ?? "the machine's Pi default model",
            thinkingLevel: resolution.thinkingLevel,
            reason: error.localizedDescription
        )
    }

    /// A machine without a declared default lets Pi choose. A declared default
    /// that the catalog does not offer is a configuration error rather than a
    /// silent fallthrough.
    private static func machineDefault(
        catalog: AgentModelCatalogResponse,
        models: [PiAvailableModel],
        machineName: String
    ) throws -> MachineDefault {
        guard let declared = catalog.defaultModel else {
            return MachineDefault(model: nil)
        }
        guard let offered = models.first(where: { $0.id == declared.fullID }) else {
            throw SmartRenameModelRoutingError.defaultModelUnavailable(
                machineName: machineName,
                model: declared.displayName
            )
        }
        return MachineDefault(model: offered)
    }

    /// The catalog does not advertise per-model effort ranges, so an explicit
    /// `reasoning: false` is the only known incompatibility. Off is always
    /// permitted, and every other selected level passes through unchanged.
    private static func effort(
        _ level: PiThinkingLevel,
        for model: PiAvailableModel?,
        machineName: String
    ) throws -> PiThinkingLevel {
        if model?.reasoning == false, level != .off {
            throw SmartRenameModelRoutingError.thinkingLevelUnsupported(
                machineName: machineName,
                model: model?.id ?? "The selected model",
                level: level
            )
        }
        return level
    }

    private struct MachineDefault {
        let model: PiAvailableModel?
    }
}
