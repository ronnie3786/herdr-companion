import SwiftUI

/// Quiet resting chrome reserves strong semantic colors for active work and
/// attention. Every state remains distinguishable by a symbol and VoiceOver.
enum SidebarRowTone {
    static func statusColor(for status: AgentStatus) -> Color {
        if status.needsAttention || status == .working {
            status.color
        } else {
            HerdrTheme.mist
        }
    }
}
