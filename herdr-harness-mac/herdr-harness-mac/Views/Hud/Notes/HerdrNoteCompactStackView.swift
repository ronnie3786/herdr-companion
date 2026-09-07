import SwiftUI

/// Compact titles grow with the note count, scrolling only at the screen edge.
struct HerdrNoteCompactStackView: View {
    let notes: HerdrHudNotesState
    let count: Int
    var maximumHeight: CGFloat?
    var openNote: (UUID) -> Void = { _ in }

    private var naturalHeight: CGFloat {
        HerdrHudPlacement.notesContentSize(.compact(count: count), isExpanded: false).height
    }

    private var viewportHeight: CGFloat { min(naturalHeight, max(0, maximumHeight ?? naturalHeight)) }

    var body: some View {
        Group {
            if viewportHeight < naturalHeight {
                VStack(spacing: 4) {
                    ScrollView(.vertical) { noteRows.padding(.trailing, 12) }
                        .scrollIndicators(.visible)
                    Label("\(count) notes · Scroll for more", systemImage: "arrow.up.arrow.down")
                        .herdrFont(.caption2)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                        .frame(height: 20)
                }
            } else {
                noteRows
            }
        }
        .frame(width: HerdrHudPlacement.noteCompactWidth + (viewportHeight < naturalHeight ? 12 : 0), height: viewportHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) notes")
    }

    private var noteRows: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.noteCompactBarSpacing) {
            ForEach(notes.notes) { note in
                Button { openNote(note.id) } label: {
                    Text(note.displayTitle)
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(note.color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .frame(
                        width: HerdrHudPlacement.noteCompactWidth,
                        height: HerdrHudPlacement.noteCompactBarHeight,
                        alignment: .leading
                    )
                    .background(note.color.fill, in: .capsule)
                    .shadow(color: HerdrTheme.ink.opacity(0.3), radius: 2, y: 1)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open note: \(note.displayTitle)")
                .accessibilityIdentifier("hud-note-compact-\(note.id)")
            }
        }
    }
}
