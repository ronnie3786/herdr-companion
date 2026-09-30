import SwiftUI

/// Explicit client-built fallback for hosts without lead capability; never an agent message.
struct FirstMateLeadBriefingScreen: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Binding var goal: String
    let openFeature: (FirstMateFeatureTarget) -> Void
    var create: ((String) -> Void)?
    var embedded = false

    init(model: HerdrAppModel, fleet: FirstMateMobileFleetStore, goal: Binding<String> = .constant(""),
         openFeature: @escaping (FirstMateFeatureTarget) -> Void, create: ((String) -> Void)? = nil, embedded: Bool = false) {
        self.model = model; self.fleet = fleet; _goal = goal; self.openFeature = openFeature; self.create = create; self.embedded = embedded
    }
    var body: some View {
        let conversations = fleet.conversations
        let briefing = FirstMateLeadBriefing.build(conversations: conversations, now: .now, calendar: .current)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Today").herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(HerdrTheme.codeFill, in: .capsule)
                    .frame(maxWidth: .infinity)
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
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("first-mate-briefing-disclosure")
                    FirstMateWrappingLayout(spacing: 3) {
                        ForEach(Array(briefing.segments.enumerated()), id: \.offset) { _, segment in
                            switch segment {
                            case .text(let text):
                                Text(text).font(HerdrProse.font(.bubble)).foregroundStyle(HerdrTheme.proseText)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .mention(let row): FirstMateFeatureCapsule(conversation: row, fleet: fleet, open: openFeature)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("first-mate-briefing-body")
                    if fleet.hosts.contains(where: { $0.error != nil }) {
                        Text("Some machines are unavailable. This summary includes their last known features.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                    }
                    if let updated = fleet.hosts.compactMap(\.lastUpdated).max() {
                        Text("Updated \(FirstMateChatTime.clock(for: updated, calendar: .current))").herdrFont(.caption2).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
                .padding(16).herdrCard(radius: HerdrTheme.Radius.panel, fill: HerdrTheme.codeFill)
                Text(model.firstMateCanControlVisibleHosts ? "Describe a new feature below, and First Mate starts it for you." : "Add a machine to start a feature.")
                    .herdrFont(.body).foregroundStyle(HerdrTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                Button("New feature", systemImage: "plus") { beginCreating() }
                    .buttonStyle(HerdrButtonStyle(kind: .outline)).disabled(!model.firstMateCanControlVisibleHosts)
                    .accessibilityIdentifier("first-mate-briefing-create")
            }
            .padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .herdrEdgeFade()
        .safeAreaBar(edge: .bottom, spacing: 0) {
            FirstMateMessageComposer(text: $goal, placeholder: "Describe a new feature", canControl: model.firstMateCanControlVisibleHosts,
                                     isSending: false, send: beginCreating)
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
        .herdrFirstMateChrome().navigationTitle("My First Mate").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarVisibility(embedded ? .visible : .hidden, for: .tabBar)
        .accessibilityElement(children: .contain).accessibilityIdentifier("first-mate-lead-briefing")
    }
    private func beginCreating() {
        if let create { create(goal) }
        else { model.beginAppNavigation(); fleet.beginCreating() }
    }
}
