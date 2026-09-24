import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("HUD new chat policy")
struct HerdrHudNewChatPolicyTests {
    @Test("The local Mac is found by loopback evidence regardless of roster order or names")
    func localMachineIgnoresOrderAndNames() {
        let remote = machine(id: "remote-1", name: "Build", url: "https://build.example.test")
        let local = machine(id: "local-1", name: "Renamed Later", url: "http://localhost:9092")
        let policy = HerdrHudNewChatPolicy(hostNames: [], addresses: [])

        #expect(policy.localMachine(in: [remote, local])?.id == local.id)
        #expect(policy.localMachine(in: [local, remote])?.id == local.id)
    }

    @Test("Host name and address evidence identifies this Mac without loopback")
    func localMachineUsesInjectedHostEvidence() {
        let remote = machine(id: "remote-1", name: "Build", url: "https://build.example.test")
        let local = machine(id: "local-1", name: "Desk", url: "https://desk.example.test")
        let byName = HerdrHudNewChatPolicy(hostNames: ["desk.example.test"], addresses: [])
        let byAddress = HerdrHudNewChatPolicy(hostNames: [], addresses: ["Desk.example.test"])

        #expect(byName.localMachine(in: [remote, local])?.id == local.id)
        #expect(byAddress.localMachine(in: [remote, local])?.id == local.id)
    }

    @Test("Ambiguous or absent host evidence requires an explicit machine selection")
    func ambiguousEvidenceReturnsNoMachine() {
        let first = machine(id: "local-1", name: "One", url: "http://localhost:9092")
        let second = machine(id: "local-2", name: "Two", url: "http://127.0.0.1:9093")
        let ambiguous = HerdrHudNewChatPolicy(hostNames: [], addresses: [])
        #expect(ambiguous.localMachine(in: [first, second]) == nil)

        let remote = machine(id: "remote-1", name: "Build", url: "https://build.example.test")
        let absent = HerdrHudNewChatPolicy(hostNames: ["unknown.example.test"], addresses: [])
        #expect(absent.localMachine(in: [remote]) == nil)
        #expect(absent.localMachine(in: []) == nil)
    }

    @Test("Two companions keep their own declared default models")
    func twoCatalogsResolveIndependently() throws {
        let firstCatalog = catalog(
            machineID: "machine-1",
            defaultModel: PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil),
            models: [
                PiAvailableModel(provider: "anthropic", modelID: "claude-sonnet", name: nil, reasoning: true, contextWindow: nil),
                PiAvailableModel(provider: "openai-codex", modelID: "gpt-5.6-luna", name: nil, reasoning: true, contextWindow: nil),
            ]
        )
        let secondCatalog = catalog(
            machineID: "machine-2",
            defaultModel: PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil),
            models: [
                PiAvailableModel(provider: "anthropic", modelID: "claude-sonnet", name: nil, reasoning: true, contextWindow: nil),
                PiAvailableModel(provider: "openai-codex", modelID: "gpt-5.6-luna", name: nil, reasoning: true, contextWindow: nil),
            ]
        )
        let policy = HerdrHudNewChatPolicy()

        let first = try policy.resolveDefaultModel(for: "machine-1", catalog: firstCatalog)
        let second = try policy.resolveDefaultModel(for: "machine-2", catalog: secondCatalog)

        #expect(first.fullID == "anthropic/claude-sonnet")
        #expect(second.fullID == "openai-codex/gpt-5.6-luna")
        #expect(first != second)
    }

    @Test("A catalog that belongs to another machine is rejected as stale")
    func staleCatalogIsRejected() {
        let firstCatalog = catalog(
            machineID: "machine-1",
            defaultModel: PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil)
        )
        let policy = HerdrHudNewChatPolicy()

        #expect(throws: HerdrHudNewChatPolicyError.staleCatalog) {
            try policy.resolveDefaultModel(for: "machine-2", catalog: firstCatalog)
        }
    }

    @Test("Missing, unreadable, and unavailable defaults are actionable errors")
    func strictDefaultResolution() {
        let policy = HerdrHudNewChatPolicy()

        #expect(throws: HerdrHudNewChatPolicyError.catalogUnavailable) {
            try policy.resolveDefaultModel(for: "machine-1", catalog: nil)
        }
        #expect(throws: HerdrHudNewChatPolicyError.catalogUnavailable) {
            try policy.resolveDefaultModel(
                for: "machine-1",
                catalog: HerdrHudMachineModelCatalog(
                    machineID: "machine-1",
                    isAvailable: false,
                    models: [],
                    defaultModel: PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil)
                )
            )
        }
        #expect(throws: HerdrHudNewChatPolicyError.missingDefaultModel) {
            try policy.resolveDefaultModel(
                for: "machine-1",
                catalog: HerdrHudMachineModelCatalog(
                    machineID: "machine-1",
                    isAvailable: true,
                    models: [
                        PiAvailableModel(provider: "anthropic", modelID: "claude-sonnet", name: nil, reasoning: true, contextWindow: nil)
                    ],
                    defaultModel: nil
                )
            )
        }
        let absentDefault = PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil)
        #expect(throws: HerdrHudNewChatPolicyError.unavailableDefaultModel(absentDefault)) {
            try policy.resolveDefaultModel(
                for: "machine-1",
                catalog: catalog(
                    machineID: "machine-1",
                    defaultModel: absentDefault,
                    models: [
                        PiAvailableModel(provider: "anthropic", modelID: "claude-sonnet", name: nil, reasoning: true, contextWindow: nil)
                    ]
                )
            )
        }
    }

    @Test("A changed default on the same machine resolves to the new declaration")
    func changedDefaultResolvesNewDeclaration() throws {
        let old = PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil)
        let new = PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil)
        let policy = HerdrHudNewChatPolicy()

        let first = try policy.resolveDefaultModel(
            for: "machine-1",
            catalog: catalog(machineID: "machine-1", defaultModel: old)
        )
        let second = try policy.resolveDefaultModel(
            for: "machine-1",
            catalog: catalog(machineID: "machine-1", defaultModel: new)
        )

        #expect(first == old)
        #expect(second == new)
    }

    @Test("A declared default is honored when the catalog cannot enumerate models")
    func declaredDefaultWithoutEnumeration() throws {
        let declared = PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil)
        let policy = HerdrHudNewChatPolicy()
        let resolved = try policy.resolveDefaultModel(
            for: "machine-1",
            catalog: catalog(machineID: "machine-1", defaultModel: declared, models: [])
        )
        #expect(resolved == declared)
    }

    @Test("An explicit override stays distinguishable from the machine default")
    func explicitChoiceIsPreserved() throws {
        let machineDefault = PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil)
        let override = PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil)
        let policy = HerdrHudNewChatPolicy()
        let catalog = catalog(machineID: "machine-1", defaultModel: machineDefault)

        let automatic = try policy.resolve(.machineDefault, for: "machine-1", catalog: catalog)
        let explicit = try policy.resolve(.explicit(override), for: "machine-1", catalog: catalog)

        #expect(automatic == machineDefault)
        #expect(explicit == override)
        #expect(HerdrHudModelChoice.machineDefault.isExplicit == false)
        #expect(HerdrHudModelChoice.explicit(override).isExplicit)
        #expect(HerdrHudModelChoice.explicit(override).explicitIdentity == override)
    }

    @Test("An explicit override the catalog does not offer is rejected")
    func explicitOverrideMustBeOffered() {
        let override = PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil)
        let policy = HerdrHudNewChatPolicy()
        let catalog = catalog(
            machineID: "machine-1",
            defaultModel: PiModelIdentity(provider: "anthropic", id: "claude-sonnet", name: nil),
            models: [
                PiAvailableModel(provider: "anthropic", modelID: "claude-sonnet", name: nil, reasoning: true, contextWindow: nil)
            ]
        )

        #expect(throws: HerdrHudNewChatPolicyError.unavailableModel(override)) {
            try policy.resolve(.explicit(override), for: "machine-1", catalog: catalog)
        }
    }

    @Test("An explicit override survives a missing catalog but not an incomplete identity")
    func explicitChoiceWithoutCatalogOrWithInvalidIdentity() throws {
        let override = PiModelIdentity(provider: "openai-codex", id: "gpt-5.6-luna", name: nil)
        let policy = HerdrHudNewChatPolicy()

        let resolved = try policy.resolve(.explicit(override), for: "machine-1", catalog: nil)
        #expect(resolved == override)

        #expect(throws: HerdrHudNewChatPolicyError.invalidModel) {
            try policy.resolve(
                .explicit(PiModelIdentity(provider: " ", id: "gpt-5.6-luna", name: nil)),
                for: "machine-1",
                catalog: nil
            )
        }
        #expect(!HerdrHudNewChatPolicy.isComplete(PiModelIdentity(provider: "anthropic", id: "", name: nil)))
    }

    private func machine(id: String, name: String, url: String) -> HerdrMachine {
        HerdrMachine(id: id, name: name, urlString: url)
    }

    private func catalog(
        machineID: String,
        defaultModel: PiModelIdentity?,
        models: [PiAvailableModel] = [
            PiAvailableModel(provider: "anthropic", modelID: "claude-sonnet", name: nil, reasoning: true, contextWindow: nil),
            PiAvailableModel(provider: "openai-codex", modelID: "gpt-5.6-luna", name: nil, reasoning: true, contextWindow: nil),
        ]
    ) -> HerdrHudMachineModelCatalog {
        HerdrHudMachineModelCatalog(
            machineID: machineID,
            isAvailable: true,
            models: models,
            defaultModel: defaultModel
        )
    }
}
