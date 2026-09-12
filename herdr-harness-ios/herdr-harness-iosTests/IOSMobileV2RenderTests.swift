import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import herdr_harness_ios

/// Isolated native component renders for the mobile-v2 pane chrome.
///
/// These snapshots exercise real SwiftUI presentation components with synthetic
/// state. They do not represent a connected conversation, network behavior, or
/// manual VoiceOver certification.
@MainActor
final class IOSMobileV2RenderTests: XCTestCase {
    private struct DynamicTypeFixture {
        let name: String
        let swiftUI: DynamicTypeSize
        let uiKit: UIContentSizeCategory
    }

    private struct HostedSnapshot {
        let image: UIImage
        let fittingSize: CGSize
        let bounds: CGRect
    }

    private let widths: [CGFloat] = [320, 390, 430]
    private let dynamicTypeSizes = [
        DynamicTypeFixture(name: "large", swiftUI: .large, uiKit: .large),
        DynamicTypeFixture(
            name: "accessibility3",
            swiftUI: .accessibility3,
            uiKit: .accessibilityExtraLarge
        ),
    ]

    func testPaneControlRenderMatrix() throws {
        let fixture = try makeFixture()
        let configuration = makeConfiguration()
        let directory = try renderDirectory()
        print("HERDR_IOS_MOBILE_V2_RENDER_DIR=\(directory.path)")

        for dynamicType in dynamicTypeSizes {
            for width in widths {
                let surface = IOSMobileV2RenderSurface(
                    model: fixture.model,
                    pane: fixture.pane,
                    store: fixture.store,
                    configuration: configuration
                )

                let snapshot = try hostAndSnapshot(
                    surface,
                    width: width,
                    dynamicType: dynamicType
                )
                assertExactWidth(snapshot, expectedWidth: width, name: "component surface")
                XCTAssertGreaterThan(
                    snapshot.bounds.height,
                    132,
                    "Header, mode bar, and composer options should all contribute visible layout"
                )

                try assertMinimumControlSizes(
                    configuration: configuration,
                    width: width,
                    dynamicType: dynamicType
                )

                let filename = "ios-mobile-v2-\(Int(width))-\(dynamicType.name).png"
                let output = directory.appending(path: filename)
                let png = try XCTUnwrap(snapshot.image.pngData())
                try png.write(to: output, options: .atomic)

                let attachment = XCTAttachment(image: snapshot.image)
                attachment.name = filename
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func assertMinimumControlSizes(
        configuration: PiPromptComposerConfiguration,
        width: CGFloat,
        dynamicType: DynamicTypeFixture
    ) throws {
        let controls: [(String, AnyView)] = [
            (
                "mode bar",
                AnyView(
                    PaneModeBar(
                        selection: .constant(.chat),
                        supportsChat: true,
                        gitAvailability: .available
                    )
                )
            ),
            (
                "model",
                AnyView(
                    PiModelPickerChip(
                        currentModel: configuration.currentModel,
                        availableModels: configuration.availableModels,
                        isLoading: false,
                        isSetting: false,
                        isEnabled: true,
                        isInteractive: true,
                        errorMessage: nil,
                        selectModel: { _ in },
                        retry: { }
                    )
                )
            ),
            (
                "thinking",
                AnyView(
                    PiThinkingLevelChip(
                        currentLevel: configuration.thinkingLevel,
                        isSetting: false,
                        isEnabled: true,
                        isInteractive: true,
                        selectLevel: { _ in }
                    )
                )
            ),
        ]

        for (name, control) in controls {
            let snapshot = try hostAndSnapshot(
                control,
                width: width,
                dynamicType: dynamicType
            )
            assertExactWidth(snapshot, expectedWidth: width, name: name)
            XCTAssertGreaterThanOrEqual(
                snapshot.fittingSize.height,
                44,
                "The \(name) control must retain a 44-point minimum target"
            )
        }
    }

    /// Hosts SwiftUI in a real UIKit window so platform-backed views such as
    /// `Menu` render their native labels. `ImageRenderer` substitutes warning
    /// placeholders for those views and rounds the three equal mode columns to
    /// a 321-point bitmap at a 320-point proposal. An integral UIKit host bound
    /// keeps logical points and backing pixels exact without masking overflow
    /// behind a tolerance.
    private func hostAndSnapshot<Content: View>(
        _ content: Content,
        width: CGFloat,
        dynamicType: DynamicTypeFixture
    ) throws -> HostedSnapshot {
        let root = AnyView(
            content
                .environment(\.dynamicTypeSize, dynamicType.swiftUI)
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(HerdrTheme.ink)
        )
        let controller = UIHostingController(rootView: root)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.traitOverrides.preferredContentSizeCategory = dynamicType.uiKit
        controller.traitOverrides.userInterfaceStyle = .dark

        // Attach before fitting. A hosting controller computes its final safe-area
        // environment only after joining a window; measuring it first clipped the
        // last Thinking row when the window later contributed bottom insets.
        let maximumSize = CGSize(width: width, height: 10_000)
        let provisionalBounds = CGRect(origin: .zero, size: maximumSize)
        let window = makeWindow(frame: provisionalBounds)
        window.traitOverrides.preferredContentSizeCategory = dynamicType.uiKit
        window.traitOverrides.userInterfaceStyle = .dark
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        controller.view.frame = provisionalBounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        let fittingSize = controller.sizeThatFits(in: maximumSize)
        let height = max(1, ceil(fittingSize.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        window.frame = bounds
        controller.view.frame = bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        var drewHierarchy = false
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { context in
            UIColor(red: 0.098, green: 0.102, blue: 0.137, alpha: 1).setFill()
            context.cgContext.fill(bounds)
            drewHierarchy = controller.view.drawHierarchy(
                in: bounds,
                afterScreenUpdates: true
            )
        }
        XCTAssertTrue(drewHierarchy, "UIKit should draw the hosted SwiftUI hierarchy")
        return HostedSnapshot(image: image, fittingSize: fittingSize, bounds: bounds)
    }

    private func makeWindow(frame: CGRect) -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
        return UIWindow(frame: frame)
    }

    private func assertExactWidth(
        _ snapshot: HostedSnapshot,
        expectedWidth: CGFloat,
        name: String
    ) {
        XCTAssertLessThanOrEqual(
            snapshot.fittingSize.width,
            expectedWidth,
            "The \(name) must fit its requested logical width"
        )
        XCTAssertEqual(snapshot.bounds.width, expectedWidth)
        XCTAssertEqual(snapshot.image.size.width, expectedWidth)
        if let cgImage = snapshot.image.cgImage {
            XCTAssertEqual(
                cgImage.width,
                Int(expectedWidth * snapshot.image.scale),
                "The \(name) backing pixels should exactly match its point width and scale"
            )
        }
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

    private func makeFixture() throws -> (
        model: HerdrAppModel,
        pane: HerdrPane,
        store: PiConversationStore
    ) {
        let suiteName = "IOSMobileV2RenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        var workspace = try XCTUnwrap(model.workspace(id: "demo1|w1"))
        let paneJSON = #"{"pane_id":"w1:p-render","terminal_id":"render-terminal","workspace_id":"w1","tab_id":"w1:t1","agent_status":"working","title":"Review a deliberately long synthetic conversation title without truncating its meaning","agent":"Pi","cwd":"/tmp/herdr-demo/garden-planner"}"#
        let pane = try JSONDecoder()
            .decode(HerdrPane.self, from: Data(paneJSON.utf8))
            .stamped(machineID: "demo1")
        workspace.panes = [pane]
        model.workspaces = [workspace]
        return (model, pane, PiConversationStore())
    }

    private func makeConfiguration() -> PiPromptComposerConfiguration {
        let model = PiAvailableModel(
            provider: "synthetic-provider",
            modelID: "synthetic-reasoning-model",
            name: "Synthetic reasoning model with a deliberately long display name",
            reasoning: true,
            contextWindow: 128_000
        )
        return PiPromptComposerConfiguration(
            capabilities: PiSemanticCapabilities(
                prompt: true,
                steer: true,
                followUp: true,
                abort: true,
                listModels: true,
                setModel: true,
                setThinkingLevel: true,
                interactionResponse: true
            ),
            phase: .idle,
            compactionActivity: nil,
            isConnected: true,
            isSubmitting: false,
            isAborting: false,
            currentModel: PiModelIdentity(
                provider: model.provider,
                id: model.modelID,
                name: model.name
            ),
            availableModels: [model],
            isLoadingModels: false,
            isSettingModel: false,
            modelCatalogError: nil,
            isModelSwitchingUnsupported: false,
            submit: { _, _ in false },
            abort: { false },
            selectModel: { _ in false },
            retryLoadModels: { },
            thinkingLevel: PiThinkingLevel.xhigh.rawValue,
            isSettingThinkingLevel: false,
            selectThinkingLevel: { _ in false }
        )
    }
}

private struct IOSMobileV2RenderSurface: View {
    let model: HerdrAppModel
    let pane: HerdrPane
    let store: PiConversationStore
    let configuration: PiPromptComposerConfiguration
    @State private var selectedMode: PaneDetailMode = .chat

    var body: some View {
        VStack(spacing: 12) {
            PaneSessionHeader(model: model, pane: pane, store: store)
            PaneModeBar(
                selection: $selectedMode,
                supportsChat: true,
                gitAvailability: .available
            )
            PiComposerOptionsBar(
                configuration: configuration,
                responseAudioPlayer: nil,
                activateResponseAudio: nil
            )
        }
        .padding(12)
    }
}
