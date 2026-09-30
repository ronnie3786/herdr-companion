import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Phone hold-to-talk authorization", .serialized)
@MainActor
struct FirstMateMobileVoiceTests {
    @Test("Only one explicit authorized completion sends; other completions preserve the original draft", arguments: ["send", "automatic", "navigation", "cancel", "background"])
    func completion(_ mode: String) async throws {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "Voice.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        let fleet = model.firstMateFleet, target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        #expect(fleet.open(target))
        let store = try #require(fleet.store(for: target))
        let material = fleet.chat.composerDrafts.draft(for: target, store: store)
        let voice = FirstMateMobileVoiceController()
        var current = true, sends = 0
        voice.begin(store: store, material: material, locked: true, isCurrent: { current }, submit: { sends += 1; return true })
        #expect(voice.phase == .locked)
        try await Task.sleep(for: .milliseconds(550))
        if mode == "navigation" { current = false }
        voice.finish(explicitSend: mode != "automatic")
        voice.finish(explicitSend: true) // A second activation cannot duplicate this operation.
        if mode == "cancel" { voice.cancel() }
        if mode == "background" { voice.cancel(preserveRecognizedText: true) }
        for _ in 0..<100 where voice.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sends == (mode == "send" ? 1 : 0))
        #expect(store.draft == (mode == "cancel" ? "" : "Please summarize the next step."))
        #expect(material.containsDictation == (mode != "cancel"))
        #expect(voice.phase == .idle)
    }

    @Test("Quick tap and too-short recording never produce a message")
    func shortAndSlide() async throws {
        let store = FirstMateStore(); store.configure(client: nil, demo: true)
        let featureID = try #require(store.selectedFeatureID)
        let material = FirstMateMobileComposerDraft(target: .init(machineID: "synthetic", featureID: featureID), lifecycle: store.lifecycle)
        let voice = FirstMateMobileVoiceController()
        var sends = 0
        voice.quickTap(); #expect(voice.hint == "Hold the mic to talk." && voice.phase == .idle)
        voice.begin(store: store, material: material, isCurrent: { true }, submit: { sends += 1; return true })
        voice.finish(explicitSend: true)
        for _ in 0..<100 where voice.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sends == 0 && store.draft.isEmpty)
        #expect(voice.hint?.contains("Nothing heard") == true)
        voice.begin(store: store, material: material, isCurrent: { true }, submit: { sends += 1; return true })
        voice.cancel()
        #expect(voice.phase == .idle && sends == 0 && store.draft.isEmpty)
    }

    @Test("A hold locks after the existing interval and release alone cannot stop a locked recording")
    func lock() async throws {
        let store = FirstMateStore(); store.configure(client: nil, demo: true)
        let material = FirstMateMobileComposerDraft(target: .init(machineID: "synthetic", featureID: try #require(store.selectedFeatureID)), lifecycle: store.lifecycle)
        let voice = FirstMateMobileVoiceController()
        voice.begin(store: store, material: material, isCurrent: { true }, submit: { false })
        #expect(voice.phase == .recording)
        try await Task.sleep(for: .milliseconds(2_750))
        #expect(voice.phase == .locked)
        voice.cancel(); #expect(voice.phase == .idle)
    }
}
