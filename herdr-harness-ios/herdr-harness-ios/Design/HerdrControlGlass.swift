import SwiftUI

/// Floating controls over the dusk use the system's Liquid Glass, the same
/// material as the tab bar, so bars read as native iOS 26 chrome. With Herdr
/// glass off (Settings → Appearance, or Reduce Transparency) they fall back
/// to an opaque chip with a hairline edge.
private struct HerdrControlGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.herdrGlassActive) private var glass
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(effect, in: shape)
        } else {
            content
                .background(HerdrTheme.chipFill, in: shape)
                .overlay {
                    shape.strokeBorder(HerdrTheme.rule(HerdrTheme.outline, contrast: contrast), lineWidth: 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        }
    }

    private var effect: Glass { interactive ? .regular.interactive() : .regular }
}

extension View {
    /// Liquid Glass for a floating control or field, or an opaque chip when
    /// Herdr glass is off.
    func herdrControlGlass<S: InsettableShape>(in shape: S, interactive: Bool = true) -> some View {
        modifier(HerdrControlGlassModifier(shape: shape, interactive: interactive))
    }

    /// A glass circle (40 pt unless given) in a 44 pt hit target, for bar buttons.
    func herdrGlassCircle(_ size: CGFloat = 40) -> some View {
        frame(width: size, height: size)
            .herdrControlGlass(in: .circle)
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
    }
}

/// Navigation bars inside First Mate stay transparent: the dusk continues
/// under them and the system scroll-edge effect keeps titles legible, so
/// there is no flat band between the status bar and the content.
private struct HerdrTransparentNavigationBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension View {
    func herdrTransparentNavigationBar() -> some View { modifier(HerdrTransparentNavigationBarModifier()) }
}

/// Scrolled content fades out at the edges of floating bars, so the screen's
/// own backdrop shows there: no band, and text never shows through the glass
/// controls. The mask is the scroll view's own frame (the region between its
/// bars, which already tracks bar height, Dynamic Type and the keyboard) with
/// a short fade at each faded edge. An unfaded edge extends into the safe
/// area, so content still runs under the system tab bar.
private struct HerdrEdgeFadeModifier: ViewModifier {
    let edges: VerticalEdge.Set
    private let length: CGFloat = 14

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                if edges.contains(.top) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: length)
                }
                Color.black
                if edges.contains(.bottom) {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: length)
                }
            }
            .ignoresSafeArea(.all, edges: unfaded)
        }
    }

    private var unfaded: Edge.Set {
        var set: Edge.Set = [.leading, .trailing]
        if !edges.contains(.top) { set.insert(.top) }
        if !edges.contains(.bottom) { set.insert(.bottom) }
        return set
    }
}

extension View {
    /// Apply to a scroll view (or List) that runs under floating bars.
    func herdrEdgeFade(_ edges: VerticalEdge.Set = [.top, .bottom]) -> some View {
        modifier(HerdrEdgeFadeModifier(edges: edges))
    }
}

extension View {
    /// A First Mate sheet's surface inside its NavigationStack: pane glass to
    /// every edge (no strip above the home indicator) under a transparent bar.
    func herdrSheetSurface() -> some View {
        background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
            .herdrNavigationBarChrome(transparent: true)
    }
}

/// The system's glass close button for a sheet's bar. The label stays
/// "Done" or "Cancel" for VoiceOver; the bar shows the standard xmark.
struct HerdrSheetCloseButton: View {
    var title = "Done"
    let action: () -> Void
    var body: some View {
        Button(role: .close, action: action) { Label(title, systemImage: "xmark") }
    }
}
