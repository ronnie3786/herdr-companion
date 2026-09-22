import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

/// Native renders of the complete Pi options bar across realistic state, width,
/// audio, and Dynamic Type combinations. Menu-backed controls are hosted by
/// UIKit; no ImageRenderer substitution is used.
@MainActor
final class IOSMobileV2RenderTests: XCTestCase {
    private struct OptionsFixture {
        let name: String
        let configuration: PiPromptComposerConfiguration
        let audioPlayer: ResponseAudioPlayer
        let expectedModelValue: String
        let expectedThinkingValue: String
        let expectedAudioLabels: [String]?
        let expectedAudioGlyphs: [String]?
        let expectsCompactCommonCase: Bool
    }

    private let widths: [CGFloat] = [320, 375, 402, 430]
    private let dynamicTypeSizes: [IOSNativeRenderHarness.DynamicTypeFixture] = [
        .defaultSize,
        .accessibility3,
    ]
    private let harness = IOSNativeRenderHarness()

    func testFullPiComposerOptionsBarRenderMatrix() async throws {
        let directory = try renderDirectory()
        print("HERDR_IOS_MOBILE_V2_RENDER_DIR=\(directory.path)")

        for fixture in optionsFixtures {
            for dynamicType in dynamicTypeSizes {
                for width in widths {
                    let bar = PiComposerOptionsBar(
                        configuration: fixture.configuration,
                        responseAudioPlayer: fixture.audioPlayer,
                        activateResponseAudio: { _ in }
                    )
                    .padding(.horizontal, 12)
                    let render = await harness.render(
                        bar,
                        width: width,
                        dynamicType: dynamicType
                    )
                    let artifactName = "options-\(fixture.name)-\(Int(width))-\(dynamicType.name)"
                    try save(render: render, name: artifactName, directory: directory)
                    try saveGeometryDiagnostics(
                        render: render,
                        name: artifactName,
                        directory: directory
                    )

                    let context = "\(fixture.name), \(Int(width))pt, \(dynamicType.name)"
                    assertRenderBounds(render, expectedWidth: width, context: context)
                    try assertPickerLayout(
                        render,
                        fixture: fixture,
                        dynamicType: dynamicType,
                        context: context
                    )
                    let audioFrames = try assertAudioLayout(
                        render,
                        fixture: fixture,
                        context: context
                    )
                    let pickerFrames = [
                        try XCTUnwrap(render.element(identifier: "pi-chat-model")).frame,
                        try XCTUnwrap(render.element(identifier: "pi-chat-thinking")).frame,
                    ]
                    for pickerFrame in pickerFrames {
                        for audioFrame in audioFrames {
                            XCTAssertFalse(
                                pickerFrame.intersects(audioFrame),
                                "Leading pickers must not overlap trailing audio: \(context)"
                            )
                        }
                    }

                    if fixture.expectsCompactCommonCase, dynamicType.name == "default" {
                        XCTAssertLessThanOrEqual(
                            render.fittingSize.height,
                            46,
                            "Normal audio-visible options should remain one 44-point row: \(context)"
                        )
                        let model = try XCTUnwrap(render.element(identifier: "pi-chat-model"))
                        let thinking = try XCTUnwrap(render.element(identifier: "pi-chat-thinking"))
                        for frame in [thinking.frame] + audioFrames {
                            XCTAssertEqual(
                                model.frame.midY,
                                frame.midY,
                                accuracy: 1,
                                "Common controls should share one row: \(context)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testFullComposerKeepsTwoPointOptionsToEditorGap() async throws {
        let fixture = try IOSMobileV2TestFixture.make(testCase: self)
        let audioPlayer = IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: true)
        let composer = PromptComposerView(
            model: fixture.model,
            pane: fixture.pane,
            workspace: fixture.workspace,
            draft: .constant("A synthetic prompt"),
            attachments: .constant([]),
            focusRequest: 0,
            piConfiguration: IOSMobileV2ConfigurationFixture.configuration(
                modelName: "Synthetic Standard",
                thinkingLevel: PiThinkingLevel.high.rawValue
            ),
            responseAudioPlayer: audioPlayer,
            activateResponseAudio: { _ in }
        )
        .padding(.horizontal, 12)

        let render = await harness.render(
            composer,
            width: 375,
            dynamicType: .defaultSize
        )
        let model = try XCTUnwrap(render.element(identifier: "pi-chat-model"))
        let thinking = try XCTUnwrap(render.element(identifier: "pi-chat-thinking"))
        let listen = try XCTUnwrap(render.element(identifier: "pi-response-audio-listen"))
        let summary = try XCTUnwrap(render.element(identifier: "pi-response-audio-tldr"))
        let editor = try XCTUnwrap(render.element(identifier: "prompt-composer"))
        let optionsBottom = [model, thinking, listen, summary].map(\.frame.maxY).max() ?? 0

        XCTAssertEqual(editor.frame.minY - optionsBottom, 2, accuracy: 0.75)
        XCTAssertLessThanOrEqual(model.frame.height, 46)
        XCTAssertFalse(listen.frame.intersects(summary.frame))

        let directory = try renderDirectory()
        try save(render: render, name: "full-composer-audio-visible", directory: directory)
        try saveGeometryDiagnostics(
            render: render,
            name: "full-composer-audio-visible",
            directory: directory
        )
    }

    private var optionsFixtures: [OptionsFixture] {
        [
            fixture(name: "short-high", model: "Sample Pro", thinking: .high, compact: true),
            fixture(name: "standard-low", model: "Sample Standard", thinking: .low, compact: true),
            fixture(
                name: "long-extra-high",
                model: "Synthetic reasoning model with a deliberately long display name",
                thinking: .xhigh,
                compact: true
            ),
            fixture(
                name: "hidden-audio",
                model: "Synthetic Standard",
                thinking: .high,
                audioVisible: false,
                compact: false
            ),
            OptionsFixture(
                name: "loading",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: nil,
                    thinkingLevel: PiThinkingLevel.high.rawValue,
                    isLoadingModels: true
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: true),
                expectedModelValue: "Loading…",
                expectedThinkingValue: "High",
                expectedAudioLabels: idleAudioLabels,
                expectedAudioGlyphs: idleAudioGlyphs,
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "setting",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Synthetic Standard",
                    thinkingLevel: PiThinkingLevel.high.rawValue,
                    isSettingModel: true,
                    isSettingThinkingLevel: true
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: true),
                expectedModelValue: "Synthetic Standard, setting",
                expectedThinkingValue: "High, setting",
                expectedAudioLabels: idleAudioLabels,
                expectedAudioGlyphs: idleAudioGlyphs,
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "disabled",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Synthetic Standard",
                    thinkingLevel: PiThinkingLevel.xhigh.rawValue,
                    isConnected: false
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                expectedModelValue: "Synthetic Standard",
                expectedThinkingValue: "Extra High",
                expectedAudioLabels: nil,
                expectedAudioGlyphs: nil,
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "catalog-error",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: nil,
                    thinkingLevel: PiThinkingLevel.high.rawValue,
                    modelCatalogError: "Synthetic catalog unavailable",
                    hasCatalogModels: false
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                expectedModelValue: "Not reported",
                expectedThinkingValue: "High",
                expectedAudioLabels: nil,
                expectedAudioGlyphs: nil,
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "empty-catalog",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: nil,
                    thinkingLevel: PiThinkingLevel.high.rawValue,
                    hasCatalogModels: false
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                expectedModelValue: "Not reported",
                expectedThinkingValue: "High",
                expectedAudioLabels: nil,
                expectedAudioGlyphs: nil,
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "read-only",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Synthetic Standard",
                    thinkingLevel: PiThinkingLevel.high.rawValue,
                    allowsModelSelection: false,
                    allowsThinkingSelection: false
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                expectedModelValue: "Synthetic Standard",
                expectedThinkingValue: "High",
                expectedAudioLabels: nil,
                expectedAudioGlyphs: nil,
                expectsCompactCommonCase: false
            ),
            audioStateFixture(
                name: "preparing",
                phase: .preparing(.listen),
                labels: ["Stop preparing response audio", "Listen to response summary"],
                glyphs: ["progress", "text.quote"]
            ),
            audioStateFixture(
                name: "playing",
                phase: .playing(.listen),
                labels: ["Pause response audio", "Listen to response summary"],
                glyphs: ["pause.fill", "text.quote"]
            ),
            audioStateFixture(
                name: "paused",
                phase: .paused(.listen),
                labels: ["Resume response audio", "Listen to response summary"],
                glyphs: ["play.fill", "text.quote"]
            ),
        ]
    }

    private var idleAudioLabels: [String] {
        ["Listen to response", "Listen to response summary"]
    }

    private var idleAudioGlyphs: [String] {
        ["speaker.wave.2.fill", "text.quote"]
    }

    private func fixture(
        name: String,
        model: String,
        thinking: PiThinkingLevel,
        audioVisible: Bool = true,
        compact: Bool
    ) -> OptionsFixture {
        OptionsFixture(
            name: name,
            configuration: IOSMobileV2ConfigurationFixture.configuration(
                modelName: model,
                thinkingLevel: thinking.rawValue
            ),
            audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: audioVisible),
            expectedModelValue: model,
            expectedThinkingValue: thinking.displayName,
            expectedAudioLabels: audioVisible ? idleAudioLabels : nil,
            expectedAudioGlyphs: audioVisible ? idleAudioGlyphs : nil,
            expectsCompactCommonCase: compact
        )
    }

    private func audioStateFixture(
        name: String,
        phase: ResponseAudioPlaybackPhase,
        labels: [String],
        glyphs: [String]
    ) -> OptionsFixture {
        OptionsFixture(
            name: name,
            configuration: IOSMobileV2ConfigurationFixture.configuration(
                modelName: "Sample Pro",
                thinkingLevel: PiThinkingLevel.high.rawValue
            ),
            audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(
                isVisible: true,
                phase: phase
            ),
            expectedModelValue: "Sample Pro",
            expectedThinkingValue: "High",
            expectedAudioLabels: labels,
            expectedAudioGlyphs: glyphs,
            expectsCompactCommonCase: true
        )
    }

    private func assertPickerLayout(
        _ render: IOSNativeRenderHarness.HostedRender,
        fixture: OptionsFixture,
        dynamicType: IOSNativeRenderHarness.DynamicTypeFixture,
        context: String
    ) throws {
        let diagnostics = render.measurementDiagnostics
        let model = try XCTUnwrap(
            render.element(identifier: "pi-chat-model"),
            "Missing real model control: \(context)\n\(diagnostics)"
        )
        let thinking = try XCTUnwrap(
            render.element(identifier: "pi-chat-thinking"),
            "Missing real Thinking control: \(context)\n\(diagnostics)"
        )

        assertMinimumControlFrame(model.frame, name: "Model", render: render, context: context)
        assertMinimumControlFrame(thinking.frame, name: "Thinking", render: render, context: context)
        XCTAssertTrue(
            model.label?.localizedCaseInsensitiveContains(fixture.expectedModelValue) == true,
            "Model state must remain accessible: \(context); label=\(model.label ?? "nil")"
        )
        XCTAssertTrue(
            thinking.label?.localizedCaseInsensitiveContains(fixture.expectedThinkingValue) == true,
            "Thinking state must remain accessible: \(context); label=\(thinking.label ?? "nil")"
        )

        let modelValue = try XCTUnwrap(render.element(identifier: "pi-chat-model-value"))
        let thinkingValue = try XCTUnwrap(render.element(identifier: "pi-chat-thinking-value"))
        for (value, control) in [(modelValue, model), (thinkingValue, thinking)] {
            XCTAssertGreaterThan(value.frame.width, 0, "A rendered picker value must not collapse: \(context)")
            XCTAssertGreaterThan(value.frame.height, 0, "A rendered picker value must remain visible: \(context)")
            XCTAssertTrue(control.frame.insetBy(dx: -0.5, dy: -0.5).contains(value.frame), context)
        }
        try assertPickerChevron(
            render,
            identifier: "pi-chat-model-chevron",
            expected: fixture.configuration.supportsModelMenu,
            valueFrame: modelValue.frame,
            controlFrame: model.frame,
            context: context
        )
        try assertPickerChevron(
            render,
            identifier: "pi-chat-thinking-chevron",
            expected: fixture.configuration.supportsThinkingMenu,
            valueFrame: thinkingValue.frame,
            controlFrame: thinking.frame,
            context: context
        )
        XCTAssertFalse(model.frame.intersects(thinking.frame), "Independent pickers must not overlap: \(context)")
        if dynamicType.name == "default" {
            XCTAssertEqual(model.frame.midY, thinking.frame.midY, accuracy: 1, "Pickers share a row: \(context)")
            XCTAssertEqual(
                thinking.frame.minX - model.frame.maxX,
                PiComposerOptionsLayout.spacing,
                accuracy: 1,
                "Thinking must immediately follow Model, including when audio is hidden: \(context)"
            )
            XCTAssertLessThanOrEqual(model.frame.height, 46, "Model remains a single quiet value row: \(context)")
            XCTAssertLessThanOrEqual(thinking.frame.height, 46, "Thinking remains a single quiet value row: \(context)")
        }

        let font = UIFont.preferredFont(
            forTextStyle: .footnote,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicType.uiKit)
        )
        XCTAssertLessThanOrEqual(
            thinkingValue.frame.height,
            ceil(font.lineHeight) + 1,
            "Thinking must not wrap or hyphenate its value: \(context)"
        )
    }

    private func assertPickerChevron(
        _ render: IOSNativeRenderHarness.HostedRender,
        identifier: String,
        expected: Bool,
        valueFrame: CGRect,
        controlFrame: CGRect,
        context: String
    ) throws {
        guard expected else {
            XCTAssertNil(render.element(identifier: identifier), "Read-only values have no chevron: \(context)")
            return
        }
        let chevron = try XCTUnwrap(render.element(identifier: identifier))
        XCTAssertEqual(chevron.label, "chevron.down", context)
        XCTAssertGreaterThan(chevron.frame.width, 0, "Chevron remains visible: \(context)")
        XCTAssertGreaterThanOrEqual(
            chevron.frame.minX,
            valueFrame.maxX + 2,
            "Chevron must follow its value rather than move to the far edge: \(context)"
        )
        XCTAssertLessThanOrEqual(
            chevron.frame.minX,
            valueFrame.maxX + 6,
            "Chevron stays adjacent to its value: \(context)"
        )
        XCTAssertTrue(controlFrame.insetBy(dx: -0.5, dy: -0.5).contains(chevron.frame), context)
    }

    @discardableResult
    private func assertAudioLayout(
        _ render: IOSNativeRenderHarness.HostedRender,
        fixture: OptionsFixture,
        context: String
    ) throws -> [CGRect] {
        guard let expectedLabels = fixture.expectedAudioLabels,
              let expectedGlyphs = fixture.expectedAudioGlyphs
        else {
            XCTAssertNil(render.element(identifier: "pi-response-audio-listen"), context)
            XCTAssertNil(render.element(identifier: "pi-response-audio-tldr"), context)
            XCTAssertNil(render.element(identifier: "pi-response-audio-listen-glyph"), context)
            XCTAssertNil(render.element(identifier: "pi-response-audio-tldr-glyph"), context)
            return []
        }

        let listen = try XCTUnwrap(render.element(identifier: "pi-response-audio-listen"))
        let summary = try XCTUnwrap(render.element(identifier: "pi-response-audio-tldr"))
        let listenGlyph = try XCTUnwrap(render.element(identifier: "pi-response-audio-listen-glyph"))
        let summaryGlyph = try XCTUnwrap(render.element(identifier: "pi-response-audio-tldr-glyph"))
        let controls = [listen, summary]
        let glyphs = [listenGlyph, summaryGlyph]

        for (index, control) in controls.enumerated() {
            assertMinimumControlFrame(
                control.frame,
                name: index == 0 ? "Listen" : "TL;DR",
                render: render,
                context: context
            )
            XCTAssertEqual(control.label, expectedLabels[index], "Accurate audio action label: \(context)")
            XCTAssertEqual(glyphs[index].label, expectedGlyphs[index], "Accurate visible audio glyph: \(context)")
            XCTAssertGreaterThan(glyphs[index].frame.width, 0, "Audio glyph remains visible: \(context)")
            XCTAssertLessThan(glyphs[index].frame.width, control.frame.width, "Audio remains icon-only: \(context)")
            XCTAssertTrue(control.frame.insetBy(dx: -0.5, dy: -0.5).contains(glyphs[index].frame))
        }
        XCTAssertNil(render.element(identifier: "pi-response-audio-listen-value"), context)
        XCTAssertNil(render.element(identifier: "pi-response-audio-tldr-value"), context)
        XCTAssertFalse(listen.frame.intersects(summary.frame), "Audio controls must not overlap: \(context)")
        XCTAssertEqual(
            summary.frame.maxX,
            render.bounds.maxX - 12,
            accuracy: 1,
            "Audio actions remain at the trailing edge: \(context)"
        )
        return controls.map(\.frame)
    }

    private func assertMinimumControlFrame(
        _ frame: CGRect,
        name: String,
        render: IOSNativeRenderHarness.HostedRender,
        context: String
    ) {
        XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) width: \(context)")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) height: \(context)")
        XCTAssertGreaterThanOrEqual(frame.minX, render.bounds.minX - 0.5, "\(name) clips left: \(context)")
        XCTAssertLessThanOrEqual(frame.maxX, render.bounds.maxX + 0.5, "\(name) clips right: \(context)")
        XCTAssertGreaterThanOrEqual(frame.minY, render.bounds.minY - 0.5, "\(name) clips top: \(context)")
        XCTAssertLessThanOrEqual(frame.maxY, render.bounds.maxY + 0.5, "\(name) clips bottom: \(context)")
    }

    private func assertRenderBounds(
        _ render: IOSNativeRenderHarness.HostedRender,
        expectedWidth: CGFloat,
        context: String
    ) {
        XCTAssertTrue(render.drewHierarchy, "UIKit should draw the hosted hierarchy: \(context)")
        XCTAssertGreaterThan(render.fittingSize.height, 0, "Options bar must be visible: \(context)")
        XCTAssertLessThanOrEqual(render.fittingSize.width, expectedWidth, "Options bar overflow: \(context)")
        XCTAssertEqual(render.bounds.width, expectedWidth)
        XCTAssertEqual(render.image.size.width, expectedWidth)
        if let cgImage = render.image.cgImage {
            XCTAssertEqual(cgImage.width, Int(expectedWidth * render.image.scale))
        }
    }

    private func save(
        render: IOSNativeRenderHarness.HostedRender,
        name: String,
        directory: URL
    ) throws {
        let filename = "\(name).png"
        let output = directory.appending(path: filename)
        let png = try XCTUnwrap(render.image.pngData())
        try png.write(to: output, options: .atomic)
        let attachment = XCTAttachment(image: render.image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func saveGeometryDiagnostics(
        render: IOSNativeRenderHarness.HostedRender,
        name: String,
        directory: URL
    ) throws {
        let filename = "\(name)-geometry.txt"
        let data = Data(render.measurementDiagnostics.utf8)
        try data.write(to: directory.appending(path: filename), options: .atomic)
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func renderDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["HERDR_IOS_RENDER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
            .appending(path: "herdr-ios-mobile-v2-renders", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
