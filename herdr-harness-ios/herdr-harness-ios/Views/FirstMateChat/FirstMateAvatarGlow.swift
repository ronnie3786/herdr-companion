import SwiftUI
import UIKit

/// The Mac avatar glow baked once per geometry/color, not a live blur on every
/// list row. The bounded cache also serves the pinned row and chat title pill.
struct FirstMateAvatarGlow: View {
    let size: CGFloat
    let color: Color
    let radius: CGFloat
    let inset: CGFloat

    var body: some View {
        Image(uiImage: Self.artwork(for: Key(size: size, color: color, radius: radius, inset: inset)))
            .resizable()
            .frame(width: size + radius * 6, height: size + radius * 6)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct Key: Hashable {
        let size: CGFloat
        let color: Color
        let radius: CGFloat
        let inset: CGFloat
    }

    @MainActor private static var cache: [Key: UIImage] = [:]

    @MainActor private static func artwork(for key: Key) -> UIImage {
        if let image = cache[key] { return image }
        let renderer = ImageRenderer(content:
            Circle().fill(key.color)
                .frame(width: max(1, key.size - key.inset * 2), height: max(1, key.size - key.inset * 2))
                .blur(radius: key.radius)
                .padding(key.inset + key.radius * 3)
        )
        renderer.scale = 3
        let image = renderer.uiImage ?? UIImage()
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }
}
