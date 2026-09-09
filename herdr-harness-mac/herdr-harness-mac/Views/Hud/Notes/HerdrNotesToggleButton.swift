import SwiftUI

struct HerdrNotesToggleButton: View {
    let notes: HerdrHudNotesState

    var body: some View {
        Button(action: notes.toggleList) {
            Image(systemName: "note.text")
                .herdrFont(.body, weight: .medium)
                .foregroundStyle(notes.isListExpanded ? HerdrTheme.accent : HerdrTheme.mist)
                .frame(width: HerdrHudPlacement.notesToggleSize, height: HerdrHudPlacement.notesToggleSize)
                .background(HerdrTheme.elevated, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(notes.isListExpanded ? "Minimize notes" : "Show notes")
        .accessibilityLabel("Notes")
        .accessibilityValue("\(notes.notes.count) notes, \(notes.isListExpanded ? "expanded" : "collapsed")")
        .accessibilityIdentifier("hud-notes-toggle")
    }
}
