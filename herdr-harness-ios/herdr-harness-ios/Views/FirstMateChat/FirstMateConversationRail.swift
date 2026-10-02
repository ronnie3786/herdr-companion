import SwiftUI

/// The iPad list folded into a rail of orbs, as in the Mac chat window: the
/// host picker, My First Mate, then every conversation with its unread dot.
/// The selected conversation gets a highlight and a leading bar.
struct FirstMateConversationRail: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let openFeature: (FirstMateFeatureTarget) -> Void
    let openLead: () -> Void
    @Environment(\.firstMateColumnGlassDrawn) private var columnGlassDrawn

    private var leadUnread: Bool {
        fleet.leadChoice.current.map { fleet.chat.leadIsUnread(machineID: $0, fleet: fleet) } ?? false
    }

    var body: some View {
        let presentation = FirstMateMobileListPresentation(fleet: fleet)
        ScrollView {
            VStack(spacing: 6) {
                if presentation.showsLead {
                    orb(selected: fleet.chat.selection == .lead, dot: leadUnread ? HerdrTheme.accent : nil,
                        label: "My First Mate" + (leadUnread ? ", unread reply" : ""), identifier: "first-mate-rail-lead", action: openLead) {
                        FirstMateFaceOrb(size: 50)
                    }
                    Rectangle().fill(HerdrTheme.outline).frame(width: 30, height: 1).padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
                ForEach(presentation.rows) { row in
                    let target = FirstMateMobileListPresentation.target(row)
                    orb(selected: fleet.chat.selection != .lead && fleet.selectedTarget == target,
                        dot: row.showsDot ? FirstMateChatStatusStyle.dotColor(for: row.hudStatus) : nil,
                        label: "\(row.name), \(FirstMateChatStatusStyle.word(for: row))\(row.showsDot ? ", new message" : "")",
                        identifier: "first-mate-rail-\(row.machineID)-\(row.featureID)", action: { openFeature(target) }) {
                        FirstMateEmojiDisc(emoji: row.emoji, size: 50)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .herdrEdgeFade()
        .safeAreaBar(edge: .top, spacing: 0) {
            FirstMateMachinePicker(model: model, fleet: fleet).padding(.vertical, 6)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Button {
                model.beginAppNavigation()
                fleet.beginCreating()
            } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .medium)).herdrGlassCircle(44)
            }
            .buttonStyle(.herdrPlain)
            .foregroundStyle(HerdrTheme.primaryText)
            .disabled(!model.firstMateCanControlVisibleHosts)
            .accessibilityLabel("New feature")
            .accessibilityIdentifier("first-mate-rail-new-feature")
            .padding(.vertical, 10)
        }
        .background { if !columnGlassDrawn { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground).ignoresSafeArea() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-conversation-rail")
    }

    private func orb<Avatar: View>(selected: Bool, dot: Color?, label: String, identifier: String,
                                   action: @escaping () -> Void, @ViewBuilder avatar: () -> Avatar) -> some View {
        Button(action: action) {
            avatar()
                .overlay(alignment: .topTrailing) {
                    if let dot {
                        Circle().fill(dot).frame(width: 12, height: 12)
                            .overlay { Circle().strokeBorder(HerdrTheme.railBackground, lineWidth: 2.5) }
                            .offset(x: 2, y: -2)
                    }
                }
                .frame(width: 64, height: 62)
                .background(selected ? HerdrTheme.inkFill(0.10) : .clear, in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .leading) {
                    if selected { Capsule().fill(HerdrTheme.primaryText).frame(width: 4, height: 30).offset(x: -10) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
