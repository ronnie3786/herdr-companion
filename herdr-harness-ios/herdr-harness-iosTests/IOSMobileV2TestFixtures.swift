import Foundation
import XCTest
@testable import herdr_harness_ios

@MainActor
struct IOSMobileV2TestFixture {
    let model: HerdrAppModel
    let workspace: HerdrWorkspace
    let pane: HerdrPane
    let store: PiConversationStore

    static func make(testCase: XCTestCase) throws -> Self {
        let suiteName = "IOSMobileV2RenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        testCase.addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        var workspace = try XCTUnwrap(model.workspace(id: "demo1|w1"))
        let paneJSON = #"{"pane_id":"w1:p-render","terminal_id":"render-terminal","workspace_id":"w1","tab_id":"w1:t1","agent_status":"working","title":"Synthetic composer layout session","agent":"Pi","cwd":"/tmp/herdr-demo/garden-planner"}"#
        let pane = try JSONDecoder()
            .decode(HerdrPane.self, from: Data(paneJSON.utf8))
            .stamped(machineID: "demo1")
        workspace.panes = [pane]
        model.workspaces = [workspace]
        return Self(
            model: model,
            workspace: workspace,
            pane: pane,
            store: PiConversationStore()
        )
    }
}

enum IOSMobileV2ConfigurationFixture {
    static func configuration(
        modelName: String?,
        thinkingLevel: String?,
        isLoadingModels: Bool = false,
        isConnected: Bool = true,
        allowsModelSelection: Bool = true,
        allowsThinkingSelection: Bool = true
    ) -> PiPromptComposerConfiguration {
        let availableModel = PiAvailableModel(
            provider: "synthetic-provider",
            modelID: "synthetic-model",
            name: modelName ?? "Synthetic available model",
            reasoning: true,
            contextWindow: 128_000
        )
        let currentModel = modelName.map {
            PiModelIdentity(
                provider: availableModel.provider,
                id: availableModel.modelID,
                name: $0
            )
        }
        return PiPromptComposerConfiguration(
            capabilities: PiSemanticCapabilities(
                prompt: true,
                steer: true,
                followUp: true,
                abort: true,
                listModels: allowsModelSelection,
                setModel: allowsModelSelection,
                setThinkingLevel: allowsThinkingSelection,
                interactionResponse: true
            ),
            phase: .idle,
            compactionActivity: nil,
            isConnected: isConnected,
            isSubmitting: false,
            isAborting: false,
            currentModel: currentModel,
            availableModels: [availableModel],
            isLoadingModels: isLoadingModels,
            isSettingModel: false,
            modelCatalogError: nil,
            isModelSwitchingUnsupported: false,
            submit: { _, _ in false },
            abort: { false },
            selectModel: { _ in false },
            retryLoadModels: { },
            thinkingLevel: thinkingLevel,
            isSettingThinkingLevel: false,
            selectThinkingLevel: { _ in false }
        )
    }

    @MainActor
    static func audioPlayer(isVisible: Bool) -> ResponseAudioPlayer {
        ResponseAudioPlayer.preview(
            capabilities: ResponseAudioCapabilities(
                ok: true,
                available: true,
                listen: true,
                tldr: true
            ),
            phase: .idle,
            hasPlayableResponse: isVisible
        )
    }
}
