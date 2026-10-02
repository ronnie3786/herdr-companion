import AppKit
import SwiftUI

extension View {
    /// Watchers sheets sit on the app's dusk glass, not the system's gray sheet.
    func watchersSheetChrome() -> some View {
        foregroundStyle(HerdrTheme.primaryText)
            .tint(HerdrTheme.accent)
            .background(alignment: .top) { HerdrHazeBand() }
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
            .preferredColorScheme(.dark)
    }
}

/// "Runs on": every machine, with whether it can host watchers right now.
struct WatcherMachineMenu: View {
    var store: WatchersStore
    @Binding var selection: String
    var body: some View {
        Menu {
            ForEach(store.sources, id: \.machineID) { source in
                let state = store.state(for: source.machineID)
                Button { selection = source.machineID } label: {
                    if selection == source.machineID { Label(title(source.machineName, state), systemImage: "checkmark") } else { Text(title(source.machineName, state)) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(dot(store.state(for: selection))).frame(width: 6, height: 6)
                Text(store.sources.isEmpty ? "No computers" : store.machineName(for: selection)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(HerdrTheme.secondaryText)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(HerdrTheme.primaryText)
            .padding(.horizontal, 10).frame(height: 28)
            .background(HerdrTheme.chipFill, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(HerdrTheme.outline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.herdrPlain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Runs on \(store.machineName(for: selection))")
    }
    private func title(_ name: String, _ state: WatcherMachineState) -> String { state.isOn ? name : "\(name) — \(state.label)" }
    private func dot(_ state: WatcherMachineState) -> Color {
        switch state {
        case .on: WatchersStyle.mint
        case .off, .needsUpdate: WatchersStyle.amber
        case .unreachable: WatchersStyle.rose
        case .checking: HerdrTheme.secondaryText
        }
    }
}

/// Shown in place of the builder or editor while the chosen machine cannot
/// host watchers: why, and the one step that fixes it.
struct WatcherMachineSetupPanel: View {
    var store: WatchersStore
    var machineID: String
    @State private var copied = false
    private var name: String { store.machineName(for: machineID) }
    private var state: WatcherMachineState { store.state(for: machineID) }
    private var changing: Bool { store.changingMachines.contains(machineID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(HerdrTheme.accent)
                    .frame(width: 38, height: 38).background(HerdrTheme.accent.opacity(0.12), in: .circle)
                    .overlay(Circle().strokeBorder(HerdrTheme.accent.opacity(0.3), lineWidth: 1))
                Text(title).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            Text(message).font(.system(size: 12.5)).foregroundStyle(HerdrTheme.proseText).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            if case .off(let canTurnOn, let lockedOff) = state {
                if canTurnOn {
                    HStack(spacing: 12) {
                        Button { Task { await store.setWatchersEnabled(true, machineID: machineID) } } label: {
                            HStack(spacing: 6) { if changing { ProgressView().controlSize(.small) } else { Image(systemName: "power") }; Text(changing ? "Turning on…" : "Turn on Watchers") }
                        }
                        .buttonStyle(HerdrButtonStyle(kind: .primary)).disabled(changing)
                        .accessibilityIdentifier("watchers-turn-on")
                        Text("Saved on \(name). Nothing runs until you create a watcher.").font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText)
                    }
                } else {
                    configSnippet(lockedOff: lockedOff)
                }
            }
            if let error = store.settingErrors[machineID] {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(WatchersStyle.rose).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22).frame(maxWidth: 460, alignment: .leading)
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(HerdrTheme.outline, lineWidth: 1))
    }
    private var icon: String {
        switch state {
        case .unreachable: "wifi.slash"
        case .needsUpdate: "arrow.down.circle"
        case .checking: "ellipsis"
        default: "eye.slash"
        }
    }
    private var title: String {
        switch state {
        case .checking: "Checking \(name)…"
        case .needsUpdate: "\(name) needs a companion update"
        case .unreachable: "\(name) isn’t reachable"
        default: "Watchers is off on \(name)"
        }
    }
    private var message: String {
        switch state {
        case .checking: "Looking for Watchers on this computer."
        case .needsUpdate: "Its companion doesn’t include Watchers yet. Update the companion on \(name), then come back here."
        case .unreachable(let detail): "Check that its companion is running and connected. \(detail)"
        case .off(_, let lockedOff):
            lockedOff
                ? "Watchers is turned off in \(name)’s companion configuration."
                : "Watchers run on \(name)’s companion, so they keep working when this Mac is asleep or the app is closed. Turn it on to create watchers there."
        case .on: ""
        }
    }
    /// For companions that cannot take the app's setting: the exact lines to add.
    private func configSnippet(lockedOff: Bool) -> some View {
        let snippet = "[machines.\(machineID).environment]\nHERDR_WATCHERS_ENABLED = \"1\""
        return VStack(alignment: .leading, spacing: 8) {
            Text(lockedOff
                 ? "Change HERDR_WATCHERS_ENABLED to \"1\" in its private configuration (or remove it so the app can manage it), then restart the companion."
                 : "This companion predates turning Watchers on from the app. Update it, or add these lines to its private configuration and restart it:")
                .font(.system(size: 11.5)).foregroundStyle(HerdrTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                Text(snippet).font(.system(size: 11, design: .monospaced)).foregroundStyle(WatchersStyle.hex(0xCFE9DD)).textSelection(.enabled)
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snippet, forType: .string); copied = true
                }
                .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.small))
            }
            .padding(10).background(Color.black.opacity(0.24), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
        }
    }
}

/// Every computer and whether Watchers is on there, with the switch for it.
struct WatchersMachinesList: View {
    var store: WatchersStore
    @State private var turningOff: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.sources.enumerated()), id: \.element.machineID) { index, source in
                if index > 0 { Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1) }
                row(source)
            }
        }
        .confirmationDialog("Turn off Watchers on \(turningOff.map(store.machineName(for:)) ?? "")?", isPresented: Binding(get: { turningOff != nil }, set: { if !$0 { turningOff = nil } })) {
            Button("Turn Off", role: .destructive) { if let id = turningOff { Task { await store.setWatchersEnabled(false, machineID: id) } } }
        } message: {
            Text("Its watchers stop waking up until you turn Watchers back on. Nothing is deleted, and a run that is already working finishes.")
        }
    }
    private func row(_ source: WatchersSource) -> some View {
        let state = store.state(for: source.machineID)
        let changing = store.changingMachines.contains(source.machineID)
        return HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 14)).foregroundStyle(HerdrTheme.secondaryText).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.machineName).font(.system(size: 12.5, weight: .medium))
                Text(detail(state, count: store.entries.filter { $0.machineID == source.machineID }.count)).font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText)
                if let error = store.settingErrors[source.machineID] { Text(error).font(.system(size: 11)).foregroundStyle(WatchersStyle.rose).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if changing { ProgressView().controlSize(.small) }
            else if state.isOn {
                Button("Turn off") { turningOff = source.machineID }.buttonStyle(HerdrButtonStyle(kind: .ghost, height: HerdrTheme.ControlHeight.small))
            } else if case .off(true, _) = state {
                Button("Turn on") { Task { await store.setWatchersEnabled(true, machineID: source.machineID) } }.buttonStyle(HerdrButtonStyle(kind: .primary, height: HerdrTheme.ControlHeight.small))
            }
        }
        .padding(.vertical, 10)
    }
    private func detail(_ state: WatcherMachineState, count: Int) -> String {
        switch state {
        case .on(let supervised):
            let watchers = count == 1 ? "1 watcher" : "\(count) watchers"
            return supervised ? "On · \(watchers)" : "On · \(watchers) · pauses whenever its companion stops"
        case .off(_, true): return "Off in its configuration"
        case .off(true, _): return "Off"
        case .off: return "Off · update its companion to turn it on here"
        case .needsUpdate: return "Needs a companion update"
        case .unreachable: return "Not reachable"
        case .checking: return "Checking…"
        }
    }
}
