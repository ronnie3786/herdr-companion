import AppKit

/// Gives hosted UI tests a local icon without depending on IconServices to
/// resolve the temporary test application bundle.
@MainActor
enum HerdrTestAppIcon {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        let icon = NSImage(size: CGSize(width: 64, height: 64), flipped: false) { bounds in
            NSColor(calibratedRed: 0.7, green: 0.6, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
        NSApplication.shared.applicationIconImage = icon
        isInstalled = true
    }
}
