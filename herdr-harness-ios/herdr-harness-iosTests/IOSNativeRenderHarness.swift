import SwiftUI
import UIKit
@testable import herdr_harness_ios

/// Draws real native Menu-backed controls and resolves layout-neutral anchors
/// into actual control/text frames. This is geometry testing, not an offscreen
/// accessibility audit; accessibility behavior belongs in the UI test target.
@MainActor
struct IOSNativeRenderHarness {
    struct DynamicTypeFixture {
        let name: String
        let swiftUI: DynamicTypeSize
        let uiKit: UIContentSizeCategory

        static let defaultSize = Self(name: "default", swiftUI: .large, uiKit: .large)
        static let accessibility3 = Self(
            name: "accessibility3",
            swiftUI: .accessibility3,
            uiKit: .accessibilityExtraLarge
        )
    }

    struct HostedRender {
        let image: UIImage
        let fittingSize: CGSize
        let bounds: CGRect
        let drewHierarchy: Bool
        let measurements: [ComposerLayoutMeasurement.Frame]

        var measurementDiagnostics: String {
            measurements.map {
                "id=\($0.identifier ?? "nil") label=\($0.label ?? "nil") frame=\($0.frame)"
            }.joined(separator: "\n")
        }

        func element(identifier: String) -> ComposerLayoutMeasurement.Frame? {
            measurements.first { $0.identifier == identifier }
        }

        func element(label: String) -> ComposerLayoutMeasurement.Frame? {
            measurements.first { $0.label == label }
        }

        func elements(labelContaining fragment: String) -> [ComposerLayoutMeasurement.Frame] {
            measurements.filter { $0.label?.localizedCaseInsensitiveContains(fragment) == true }
        }
    }

    @MainActor
    private final class Collector {
        var frames: [ComposerLayoutMeasurement.Frame] = []
    }

    func render<Content: View>(
        _ content: Content,
        width: CGFloat,
        dynamicType: DynamicTypeFixture
    ) async -> HostedRender {
        let collector = Collector()
        let root = AnyView(
            content
                .environment(\.dynamicTypeSize, dynamicType.swiftUI)
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(HerdrTheme.ink)
                .overlayPreferenceValue(ComposerLayoutMeasurement.Anchors.self) { sources in
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ComposerLayoutMeasurement.Frames.self,
                            value: sources.keys.sorted().compactMap { identifier -> ComposerLayoutMeasurement.Frame? in
                                guard let source = sources[identifier] else { return nil }
                                return ComposerLayoutMeasurement.Frame(
                                    identifier: identifier,
                                    label: source.label,
                                    frame: geometry[source.bounds]
                                )
                            }
                        )
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(ComposerLayoutMeasurement.Frames.self) { frames in
                    Task { @MainActor in collector.frames = frames }
                }
        )
        let controller = UIHostingController(rootView: root)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.traitOverrides.preferredContentSizeCategory = dynamicType.uiKit
        controller.traitOverrides.userInterfaceStyle = .dark

        let maximumSize = CGSize(width: width, height: 10_000)
        let provisionalBounds = CGRect(origin: .zero, size: maximumSize)
        let previousWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let window = makeWindow(frame: provisionalBounds)
        window.traitOverrides.preferredContentSizeCategory = dynamicType.uiKit
        window.traitOverrides.userInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        controller.view.frame = provisionalBounds
        settle(window: window, controller: controller)
        await Task.yield()

        let fittingSize = controller.sizeThatFits(in: maximumSize)
        let bounds = CGRect(x: 0, y: 0, width: width, height: max(1, ceil(fittingSize.height)))
        window.frame = bounds
        controller.view.frame = bounds
        settle(window: window, controller: controller)
        await Task.yield()

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor(HerdrTheme.ink).setFill()
            context.cgContext.fill(bounds)
            drewHierarchy = controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        return HostedRender(
            image: image,
            fittingSize: fittingSize,
            bounds: bounds,
            drewHierarchy: drewHierarchy,
            measurements: collector.frames
        )
    }

    private func settle(window: UIWindow, controller: UIViewController) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func makeWindow(frame: CGRect) -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
        return UIWindow(frame: frame)
    }
}
