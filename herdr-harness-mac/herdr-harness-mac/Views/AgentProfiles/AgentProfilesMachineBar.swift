import SwiftUI

/// One chip per machine, showing which profile each machine's agents use.
struct AgentProfilesMachineBar: View {
    let store: AgentProfilesStore
    let select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.machines) { machine in
                    chip(machine)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Machines")
        .accessibilityIdentifier("agent-profiles-machines")
    }

    private func chip(_ machine: HerdrMachine) -> some View {
        let isSelected = machine.id == store.selectedMachineID
        let suggestionCount = store.suggestionCountForProfileUsed(on: machine.id)
        return Button {
            select(machine.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: machine.role == "development" ? "server.rack" : "desktopcomputer")
                    .herdrFont(.body)
                    .foregroundStyle(isSelected ? HerdrTheme.accent : HerdrTheme.muted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.name)
                        .herdrFont(.callout, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                    detail(for: machine)
                        .herdrFont(.caption)
                        .lineLimit(1)
                }
                if suggestionCount > 0 {
                    Text("\(suggestionCount)")
                        .herdrFont(.caption2, weight: .bold, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HerdrTheme.mauve, in: Capsule())
                        .accessibilityLabel("\(suggestionCount) suggested \(suggestionCount == 1 ? "edit" : "edits")")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 140, minHeight: 44, alignment: .leading)
            .background(
                isSelected ? HerdrTheme.elevated : HerdrTheme.ink.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? HerdrTheme.accent.opacity(0.75) : HerdrTheme.separator,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent-profiles-machine-\(machine.id)")
    }

    @ViewBuilder
    private func detail(for machine: HerdrMachine) -> some View {
        switch store.status(for: machine.id) {
        case .loading:
            Text("Loading…").foregroundStyle(HerdrTheme.muted)
        case .unavailable:
            Label("Offline", systemImage: "wifi.slash")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(HerdrTheme.alert)
        case .needsUpdate:
            Label("Needs update", systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(HerdrTheme.warning)
        case .loaded:
            if let name = store.profileName(for: machine.id) {
                Text(name).foregroundStyle(HerdrTheme.mist)
            } else {
                Text("No profile").foregroundStyle(HerdrTheme.muted)
            }
        }
    }
}
