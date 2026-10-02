import SwiftUI
import XCTest
@testable import herdr_harness_ios

@MainActor
final class FirstMateComposerRenderTests: XCTestCase {
    func testComposerMaterialVoiceAndSheetsAtPhoneWidthsAndCap() async throws {
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: ["-HerdrFirstMateDemo", "-HerdrFirstMateComposerScenarios"],
            userDefaults: UserDefaults(suiteName: "ComposerRenders.\(UUID())")!, bootstrapMachines: [])
        await model.observeFirstMate()
        let fleet = model.firstMateFleet, target = FirstMateFeatureTarget(machineID: "demo1", featureID: "demo-receipts")
        XCTAssertTrue(fleet.open(target))
        let store = try XCTUnwrap(fleet.store(for: target)), context = store.operationContext
        let lease = store.acquireControlLease(available: true)
        defer { store.releaseControlLease(lease) }
        let material = fleet.chat.composerDrafts.draft(for: target, store: store)
        let file = FileManager.default.temporaryDirectory.appending(path: "synthetic-composer-\(UUID()).txt")
        try Data("Synthetic render attachment".utf8).write(to: file)
        material.enqueue([try AttachmentPolicy.candidate(for: file, ownership: .appTemporary)],
            store: store, context: context, generation: material.generation, canUpload: { true })
        for _ in 0..<100 where material.blocksSending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(material.attachments.first?.status, .uploaded)
        material.edit("@Receipt", store: store, context: context)
        let message = try XCTUnwrap(store.snapshot?.messages.first { FirstMateFeedbackEligibility.isEligible($0) })
        let request = try XCTUnwrap(FirstMateMobileFeedbackRequest.capture(message, target: target, store: store, fleet: fleet))
        for width: CGFloat in [320, 402] {
            for size in [IOSNativeRenderHarness.DynamicTypeFixture.defaultSize, .accessibility3] {
                let composer = await IOSNativeRenderHarness().render(
                    FirstMateConversationComposer(model: model, fleet: fleet, store: store, material: material, target: target,
                        placeholder: "Message Receipt export", canControl: true, active: true, send: { false },
                        openDocuments: {}, presentationChanged: { _ in }).padding(16),
                    width: width, dynamicType: size, background: .dusk)
                try control("composer-plus-control", composer, width: width)
                try control("composer-send-control", composer, width: width)
                try control("composer-microphone-control", composer, width: width)
                for item in material.attachments {
                    try control("composer-attachment-remove-\(item.id)", composer, width: width)
                }
                try save(composer, "composer-material-\(Int(width))-\(size.name)")
                let voice = FirstMateMobileVoiceController()
                voice.begin(store: store, material: material, isCurrent: { true })
                let listening = await IOSNativeRenderHarness().render(
                    FirstMateMessageComposer(text: .constant(""), placeholder: "Message First Mate", canControl: true,
                        isSending: false, send: {}, openDocuments: {}, voice: voice, beginVoice: {}).padding(16),
                    width: width, dynamicType: size, background: .dusk)
                try control("composer-microphone-control", listening, width: width)
                try save(listening, "composer-listening-\(Int(width))-\(size.name)")
                voice.cancel()
                let modelSettings = await IOSNativeRenderHarness().render(
                    FirstMateMobileModelControls(store: store, context: context, canControl: true).frame(height: 840),
                    width: width, dynamicType: size, background: .dusk)
                try save(modelSettings, "composer-model-\(Int(width))-\(size.name)")
                let contextSheet = await IOSNativeRenderHarness().render(
                    FirstMateMobileContextSheet(store: store, context: context).frame(height: 840),
                    width: width, dynamicType: size, background: .dusk)
                try save(contextSheet, "composer-context-\(Int(width))-\(size.name)")
                let feedback = await IOSNativeRenderHarness().render(
                    FirstMateMobileFeedbackEditor(request: request, fleet: fleet).frame(height: 840),
                    width: width, dynamicType: size, background: .dusk)
                try save(feedback, "composer-feedback-\(Int(width))-\(size.name)")
            }
        }
        material.discard()
    }

    private func control(_ id: String, _ render: IOSNativeRenderHarness.HostedRender, width: CGFloat) throws {
        let frame = try XCTUnwrap(render.element(identifier: id), render.measurementDiagnostics).frame
        XCTAssertGreaterThanOrEqual(frame.width, 43.99, id); XCTAssertGreaterThanOrEqual(frame.height, 43.99, id)
        XCTAssertGreaterThanOrEqual(frame.minX, -0.01, id); XCTAssertLessThanOrEqual(frame.maxX, width + 0.01, id)
        XCTAssertGreaterThanOrEqual(frame.minY, -0.01, id); XCTAssertLessThanOrEqual(frame.maxY, render.bounds.height + 0.01, id)
    }
    private func save(_ render: IOSNativeRenderHarness.HostedRender, _ name: String) throws {
        XCTAssertTrue(render.drewHierarchy)
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-composer-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(render.image.pngData()).write(to: folder.appending(path: name + ".png"))
        let image = XCTAttachment(image: render.image); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
