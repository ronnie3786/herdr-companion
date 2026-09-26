import SwiftUI

/// The HUD's App Shots notice. Nothing renders while idle, so the resting HUD is
/// unchanged; a detected trigger, a staged attachment, and a capture failure are
/// all visible where the user is already looking.
struct HerdrHudAppShotStatusView: View {
    let controller: HerdrHudController
    var showsFullTitle: Bool = false

    var body: some View {
        if let notice = HerdrHudAppShotNotice.notice(for: controller.appShotStatus) {
            HStack(spacing: 6) {
                Image(systemName: notice.symbol)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                Text(notice.title)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: notice.isFailure ? .semibold : .regular)
                    .lineLimit(showsFullTitle ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(notice.isFailure ? HerdrTheme.alert : HerdrTheme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HerdrTheme.windowBackground, in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(notice.isFailure ? HerdrTheme.alert : HerdrTheme.outline, lineWidth: 1)
            }
            .shadow(color: HerdrTheme.ink.opacity(0.24), radius: 8, y: 3)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hud-app-shot-status")
        }
    }
}
