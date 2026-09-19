import SwiftUI

struct HerdrHudRunningRowView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession
    @AppStorage(ChatActivityPreferences.groupAllClankingActivityKey)
    private var groupAllClankingActivity = ChatActivityPreferences.defaultGroupAllClankingActivity

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.accent)
            Text(statusText)
                .herdrFont(.caption, monospacedDigit: true)
                .foregroundStyle(HerdrTheme.mist)
            Spacer()
            Button("Stop", action: stop)
                .buttonStyle(.bordered)
                .tint(HerdrTheme.alert)
                .controlSize(.small)
        }
    }

    private func stop() {
        Task { await session.stop(model: model) }
    }

    private var statusText: String {
        if groupAllClankingActivity {
            return "Working · \(session.elapsedSeconds)s"
        }
        guard session.liveStepCount > 0 else {
            return "Thinking… \(session.elapsedSeconds)s"
        }
        return "Clanking… \(session.liveStepCount) steps · \(session.elapsedSeconds)s"
    }
}
