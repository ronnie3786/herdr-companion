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
        let audioIsVisible: Bool
        let expectedModelValue: String
        let expectedThinkingValue: String
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
                        width: width,
                        dynamicType: dynamicType,
                        context: context
                    )
                    try assertAudioLayout(render, fixture: fixture, context: context)

                    if fixture.expectsCompactCommonCase, dynamicType.name == "default" {
                        XCTAssertLessThanOrEqual(
                            render.fittingSize.height,
                            68,
                            "Common short-model options should remain a compact single row: \(context)"
                        )
                        let model = try XCTUnwrap(render.element(identifier: "pi-chat-model"))
                        let thinking = try XCTUnwrap(render.element(identifier: "pi-chat-thinking"))
                        XCTAssertEqual(
                            model.frame.midY,
                            thinking.frame.midY,
                            accuracy: 1,
                            "Common controls should share one row: \(context)"
                        )
                    }

                }
            }
        }
    }

    private var optionsFixtures: [OptionsFixture] {
        [
            OptionsFixture(
                name: "short-high-hidden-audio",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Sample Pro",
                    thinkingLevel: PiThinkingLevel.high.rawValue
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                audioIsVisible: false,
                expectedModelValue: "Sample Pro",
                expectedThinkingValue: "High",
                expectsCompactCommonCase: true
            ),
            OptionsFixture(
                name: "standard-high-hidden-audio",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Synthetic Standard",
                    thinkingLevel: PiThinkingLevel.high.rawValue
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                audioIsVisible: false,
                expectedModelValue: "Synthetic Standard",
                expectedThinkingValue: "High",
                expectsCompactCommonCase: true
            ),
            OptionsFixture(
                name: "short-high-visible-audio",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Synthetic Standard",
                    thinkingLevel: PiThinkingLevel.high.rawValue
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: true),
                audioIsVisible: true,
                expectedModelValue: "Synthetic Standard",
                expectedThinkingValue: "High",
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "long-extra-high-visible-audio",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Synthetic reasoning model with a deliberately long display name",
                    thinkingLevel: PiThinkingLevel.xhigh.rawValue
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: true),
                audioIsVisible: true,
                expectedModelValue: "Synthetic reasoning model with a deliberately long display name",
                expectedThinkingValue: "Extra High",
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "unknown-hidden-audio",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: nil,
                    thinkingLevel: nil
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                audioIsVisible: false,
                expectedModelValue: "Not reported",
                expectedThinkingValue: "Not reported",
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "loading-visible-audio",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: nil,
                    thinkingLevel: PiThinkingLevel.high.rawValue,
                    isLoadingModels: true
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: true),
                audioIsVisible: true,
                expectedModelValue: "Loading…",
                expectedThinkingValue: "High",
                expectsCompactCommonCase: false
            ),
            OptionsFixture(
                name: "disabled-hidden-audio",
                configuration: IOSMobileV2ConfigurationFixture.configuration(
                    modelName: "Synthetic Standard",
                    thinkingLevel: PiThinkingLevel.xhigh.rawValue,
                    isConnected: false
                ),
                audioPlayer: IOSMobileV2ConfigurationFixture.audioPlayer(isVisible: false),
                audioIsVisible: false,
                expectedModelValue: "Synthetic Standard",
                expectedThinkingValue: "Extra High",
                expectsCompactCommonCase: false
            ),
        ]
    }

    private func assertPickerLayout(
        _ render: IOSNativeRenderHarness.HostedRender,
        fixture: OptionsFixture,
        width: CGFloat,
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
            "Model value must remain present: \(context); label=\(model.label ?? "nil")"
        )
        XCTAssertTrue(
            thinking.label?.localizedCaseInsensitiveContains(fixture.expectedThinkingValue) == true,
            "Thinking value must remain present: \(context); label=\(thinking.label ?? "nil")"
        )

        let modelValue = try XCTUnwrap(render.element(identifier: "pi-chat-model-value"))
        let thinkingValue = try XCTUnwrap(render.element(identifier: "pi-chat-thinking-value"))
        for (value, control) in [(modelValue, model), (thinkingValue, thinking)] {
            XCTAssertGreaterThan(value.frame.width, 0, "A rendered picker value must not collapse: \(context)")
            XCTAssertGreaterThan(value.frame.height, 0, "A rendered picker value must remain visible: \(context)")
            XCTAssertTrue(control.frame.insetBy(dx: -0.5, dy: -0.5).contains(value.frame), context)
        }
        XCTAssertFalse(model.frame.intersects(thinking.frame), "Independent pickers must not overlap: \(context)")

        let font = UIFont.preferredFont(
            forTextStyle: .callout,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicType.uiKit)
        )
        XCTAssertLessThanOrEqual(
            thinkingValue.frame.height, ceil(font.lineHeight) + 1,
            "Thinking must not wrap or hyphenate its value: \(context)"
        )
    }

    private func assertAudioLayout(
        _ render: IOSNativeRenderHarness.HostedRender,
        fixture: OptionsFixture,
        context: String
    ) throws {
        let listen = render.element(label: "Listen to response")
        let summary = render.element(label: "Listen to response summary")
        if fixture.audioIsVisible {
            let listen = try XCTUnwrap(listen, "Missing visible Listen control: \(context)")
            let summary = try XCTUnwrap(summary, "Missing visible summary control: \(context)")
            assertMinimumControlFrame(listen.frame, name: "Listen", render: render, context: context)
            assertMinimumControlFrame(summary.frame, name: "TL;DR", render: render, context: context)
        } else {
            XCTAssertNil(listen, "Hidden nonnil audio player must not reserve a Listen control: \(context)")
            XCTAssertNil(summary, "Hidden nonnil audio player must not reserve a summary control: \(context)")
        }
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
