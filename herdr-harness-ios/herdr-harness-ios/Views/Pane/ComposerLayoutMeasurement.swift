import SwiftUI

#if DEBUG
/// Layout-neutral measurements for native component tests. Offscreen unit-test
/// hosts do not activate the system accessibility tree; these anchors measure
/// the real controls instead. Accessibility behavior is tested by UI tests.
enum ComposerLayoutMeasurement {
    struct Source {
        let bounds: Anchor<CGRect>
        let label: String?
    }

    struct Frame: Equatable, Sendable {
        let identifier: String?
        let label: String?
        let frame: CGRect
    }

    struct Anchors: PreferenceKey {
        static var defaultValue: [String: Source] { [:] }

        static func reduce(value: inout [String: Source], nextValue: () -> [String: Source]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }

    struct Frames: PreferenceKey {
        static var defaultValue: [Frame] { [] }

        static func reduce(value: inout [Frame], nextValue: () -> [Frame]) {
            value.append(contentsOf: nextValue())
        }
    }
}
#endif

extension View {
    /// Adds no size, padding, or layout constraints. Release builds are identity.
    @ViewBuilder
    func composerLayoutMeasurement(id: String, label: String? = nil) -> some View {
        #if DEBUG
        transformAnchorPreference(key: ComposerLayoutMeasurement.Anchors.self, value: .bounds) { sources, bounds in
            sources[id] = ComposerLayoutMeasurement.Source(bounds: bounds, label: label)
        }
        #else
        self
        #endif
    }
}
