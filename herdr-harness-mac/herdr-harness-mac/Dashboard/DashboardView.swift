import SwiftUI

struct DashboardView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let entries: [DashboardFeatureEntry]
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var dashboard = shell.dashboard
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    Text("Herdr Companion").herdrFont(.title2, weight: .medium)
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(HerdrTheme.muted)
                        TextField("Search this dashboard", text: $dashboard.search)
                            .textFieldStyle(.plain).herdrFont(.subheadline)
                            .accessibilityIdentifier("dashboard-search")
                        if !dashboard.search.isEmpty {
                            Button("Clear search", systemImage: "xmark.circle.fill") { dashboard.search = "" }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(HerdrTheme.muted)
                        }
                    }.padding(9).frame(maxWidth: 290)
                        .background(HerdrTheme.input, in: .rect(cornerRadius: 7))
                    DashboardFocusToggle(isOn: $dashboard.focusMode)
                }.padding(.horizontal, 24).padding(.vertical, 18)
                Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        DashboardFirstMatesSection(model: model, shell: shell, entries: entries)
                        if geometry.size.width >= 980 {
                            HStack(alignment: .top, spacing: 32) {
                                DashboardReviewsSection(model: model, shell: shell)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                DashboardChatsSection(model: model, shell: shell)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }.padding(.horizontal, 24)
                        } else {
                            VStack(alignment: .leading, spacing: 32) {
                                DashboardReviewsSection(model: model, shell: shell)
                                DashboardChatsSection(model: model, shell: shell)
                            }.padding(.horizontal, 24)
                        }
                    }.padding(.vertical, 24)
                }
            }
        }
        .background(HerdrTheme.graphite).foregroundStyle(HerdrTheme.text)
        .tint(HerdrTheme.controlAccent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard")
        .task(id: refreshIdentity) {
            guard scenePhase == .active, !model.isDemoMode else { return }
            var tick = 0
            while !Task.isCancelled {
                let failure = await shell.prReview.refreshDashboard(requestGitHubRefresh: tick % 6 == 0)
                guard !Task.isCancelled else { return }
                if tick % 6 == 0 { dashboard.reviewRefreshError = failure }
                tick += 1
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private var refreshIdentity: String {
        "\(scenePhase)-\(model.connectionGeneration)-\(shell.prReview.currentMachineID ?? "")-\(model.isDemoMode)"
    }
}
