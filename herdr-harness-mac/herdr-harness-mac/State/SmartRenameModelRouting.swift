import Foundation

/// The model and effort a Smart Rename ask should use, plus an optional
/// explanation when a saved preference could not be honored. `modelID == nil`
/// means omit `model` and let the execution machine's Pi installation pick its
/// configured default.
struct SmartRenameModelResolution: Equatable, Sendable {
    let modelID: String?
    let thinkingLevel: PiThinkingLevel
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

    var errorDescription: String? {
        switch self {
        case let .catalogUnavailable(machineName):
            "Couldn't read the models available on \(machineName). Check that its companion is connected, then try Smart Rename again."
        case let .catalogEmpty(machineName):
            "\(machineName)'s Pi installation reported no available models. Configure a provider there, then try Smart Rename again."
        case let .defaultModelUnavailable(machineName, model):
            "\(machineName)'s default model \(model) is missing from its available model list. Update the Pi default there or choose a Smart Rename model in Settings."
        }
    }
}

/// Smart Rename keeps its own model/effort policy instead of the general
/// `AgentModelResolver`: naming must know the execution machine's declared
/// default, must surface an unavailable preference without rewriting it, and
/// must send Off when the resolved model cannot reason. Provider probing,
/// credential inspection, arbitrary retries, and cross-machine execution
/// fallback are intentionally out of scope.
enum SmartRenameModelRouting {
    /// Pure catalog seam. `preference` is the effective naming preference after
    /// inheritance (nil or blank means "the machine's default"). The stored
    /// preference is never mutated here; callers retain it and only the
    /// request's model changes.
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
        if !wanted.isEmpty, let offered = catalog.models.first(where: { $0.id == wanted }) {
            return SmartRenameModelResolution(
                modelID: offered.id,
                thinkingLevel: effort(thinkingLevel, for: offered),
                notice: nil
            )
        }

        let fallback = try machineDefault(
            catalog: catalog,
            models: catalog.models,
            machineName: machineName
        )
        let notice = wanted.isEmpty
            ? nil
            : "\(wanted) isn't offered by \(machineName). Smart Rename will use \(fallback.description) until you pick an available model."
        return SmartRenameModelResolution(
            modelID: fallback.model?.id,
            thinkingLevel: effort(thinkingLevel, for: fallback.model),
            notice: notice
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
        let machineName = appModel.machines.first { $0.id == executionMachineID }?.name
            ?? executionMachineID
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
    /// `reasoning: false` is the only override. Everything else keeps the
    /// user's selection, including Off.
    private static func effort(
        _ level: PiThinkingLevel,
        for model: PiAvailableModel?
    ) -> PiThinkingLevel {
        model?.reasoning == false ? .off : level
    }

    private struct MachineDefault {
        let model: PiAvailableModel?

        var description: String {
            model?.displayName ?? "the machine's Pi default"
        }
    }
}
