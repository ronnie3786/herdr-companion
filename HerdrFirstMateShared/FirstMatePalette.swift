import SwiftUI

struct FirstMatePalette {
    var scheme: ColorScheme
    var background: Color { scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.15) : Color(red: 0.99, green: 0.99, blue: 1) }
    var sidebar: Color { scheme == .dark ? Color(red: 0.075, green: 0.085, blue: 0.12) : Color(red: 0.95, green: 0.955, blue: 0.975) }
    var surface: Color { scheme == .dark ? Color(red: 0.14, green: 0.15, blue: 0.20) : Color(red: 0.955, green: 0.96, blue: 0.975) }
    var accent: Color { scheme == .dark ? Color(red: 0.70, green: 0.67, blue: 1) : Color(red: 0.38, green: 0.32, blue: 0.70) }
    var text: Color { scheme == .dark ? Color(red: 0.91, green: 0.92, blue: 0.97) : Color(red: 0.12, green: 0.14, blue: 0.20) }
    var secondaryText: Color { scheme == .dark ? Color(red: 0.68, green: 0.71, blue: 0.80) : Color(red: 0.35, green: 0.38, blue: 0.47) }
    var line: Color { text.opacity(0.12) }
}
