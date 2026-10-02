import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("First Mate tap dictation", .serialized)
@MainActor
struct FirstMateMobileVoiceTests {
    @Test("Stopping dictation preserves text in its original draft without sending", arguments: ["stop", "navigation", "cancel", "background", "edited"])
    func completion(_ mode: String) async throws {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo"],
            userDefaults: UserDefaults(suiteName: "Voice.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        let fleet = model.firstMateFleet, target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        #expect(fleet.open(target))
        let store = try #require(fleet.store(for: target))
        let context = store.operationContext
        let material = fleet.chat.composerDrafts.draft(for: target, store: store)
        material.edit("Keep my typed introduction.", store: store, context: context)
        let messageIDs = store.snapshot?.messages.map(\.id)
        let voice = FirstMateMobileVoiceController()
        var current = true
        voice.begin(store: store, material: material, isCurrent: { current })
        #expect(voice.phase == .locked, "One activation starts hands-free recording immediately")
        try await Task.sleep(for: .milliseconds(550))
        if mode == "navigation" { current = false }
        voice.finish()
        voice.finish() // A second activation cannot duplicate this operation.
        if mode == "cancel" { voice.cancel() }
        if mode == "background" { voice.cancel(preserveRecognizedText: true) }
        if mode == "edited" { material.edit("A newer draft.", store: store, context: context) }
        for _ in 0..<100 where voice.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.snapshot?.messages.map(\.id) == messageIDs)
        #expect(!store.isSending)
        if mode == "edited" {
            #expect(store.draft == "A newer draft.")
            #expect(material.recoveredVoice == "Please summarize the next step.")
        } else {
            #expect(store.draft == (mode == "cancel" ? "Keep my typed introduction." : "Keep my typed introduction.\nPlease summarize the next step."))
            #expect(material.containsDictation == (mode != "cancel"))
        }
        #expect(voice.phase == .idle)
    }

    @Test("Too-short and cancelled recordings leave the draft untouched")
    func shortAndCancel() async throws {
        let store = FirstMateStore(); store.configure(client: nil, demo: true)
        let featureID = try #require(store.selectedFeatureID)
        let material = FirstMateMobileComposerDraft(target: .init(machineID: "synthetic", featureID: featureID), lifecycle: store.lifecycle)
        let voice = FirstMateMobileVoiceController()
        voice.begin(store: store, material: material, isCurrent: { true })
        voice.finish()
        for _ in 0..<100 where voice.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.draft.isEmpty)
        #expect(voice.hint?.contains("Nothing heard") == true)
        voice.begin(store: store, material: material, isCurrent: { true })
        voice.cancel()
        #expect(voice.phase == .idle && store.draft.isEmpty)
    }

    @Test("A revoked conversation cannot begin dictation")
    func revokedOwner() throws {
        let store = FirstMateStore(); store.configure(client: nil, demo: true)
        let material = FirstMateMobileComposerDraft(target: .init(machineID: "synthetic", featureID: try #require(store.selectedFeatureID)), lifecycle: store.lifecycle)
        let voice = FirstMateMobileVoiceController()
        voice.begin(store: store, material: material, isCurrent: { false })
        #expect(voice.phase == .idle)
    }
}
