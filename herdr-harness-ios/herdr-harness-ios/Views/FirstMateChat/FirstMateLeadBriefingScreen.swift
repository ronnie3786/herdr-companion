import SwiftUI

/// Phase 2's explicit client-built overview, not a synthetic agent reply. The
/// real lead transcript/composer is adopted in Phase 4 without changing owners.
struct FirstMateLeadBriefingScreen: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let openFeature: (FirstMateFeatureTarget) -> Void

    var body: some View {
        let conversations = fleet.conversations
        let briefing = FirstMateLeadBriefing.build(conversations: conversations, now: .now, calendar: .current)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    FirstMateFaceOrb(size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("My First Mate").herdrFont(.headline).foregroundStyle(HerdrTheme.primaryText)
                        Text(FirstMateLeadBriefing.headerSubtitle(conversations: conversations))
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HerdrMicroLabel(text: "Summary")
                    Text("Built from your features. Not a message from an agent.")
                        .herdrFont(.footnote).foregroundStyle(HerdrTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("first-mate-briefing-disclosure")
                    Text(briefing.plainText)
                        .font(HerdrProse.font(.bubble)).lineSpacing(HerdrProse.lineSpacing(.bubble))
                        .foregroundStyle(HerdrTheme.proseText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("first-mate-briefing-body")
                    if fleet.hosts.contains(where: { $0.error != nil }) {
                        Text("Some machines are unavailable. This summary includes their last known features.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                    }
                    if let updated = fleet.hosts.compactMap(\.lastUpdated).max() {
                        Text("Updated \(updated, style: .time)").herdrFont(.caption2).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
                .padding(16).herdrCard(radius: HerdrTheme.Radius.panel, fill: HerdrTheme.codeFill)

                ForEach(conversations.filter { $0.hudStatus.needsYou }) { row in
                    Button { openFeature(FirstMateMobileListPresentation.target(row)) } label: {
                        HStack(spacing: 12) {
                            FirstMateEmojiDisc(emoji: row.emoji, size: 32)
                            Text(row.name).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").foregroundStyle(HerdrTheme.iconTint)
                        }
                        .padding(12).frame(minHeight: 44)
                    }
                    .buttonStyle(FirstMateConversationButtonStyle())
                    .accessibilityIdentifier("first-mate-briefing-feature-\(row.machineID)-\(row.featureID)")
                }
                Button("New feature", systemImage: "plus") {
                    model.beginAppNavigation()
                    fleet.beginCreating()
                }
                .buttonStyle(HerdrButtonStyle(kind: .primary))
                .disabled(!model.firstMateCanControlVisibleHosts)
                .accessibilityIdentifier("first-mate-briefing-create")
            }
            .padding(20)
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
        .herdrFirstMateChrome()
        .navigationTitle("My First Mate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-lead-briefing")
    }
}
