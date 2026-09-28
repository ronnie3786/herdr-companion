import SwiftUI

/// A stage's agents and documents as 22pt chips (MonoCode's `.chipdoc`).
struct FirstMateResourceButtons: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let visit: FirstMateVisit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let agents = snapshot.agents(for: visit.id)
        let documents = snapshot.documents(for: visit.id)
        HStack(spacing: 6) {
            Menu {
                ForEach(agents) { agent in
                    Button { Task { await store.open(.session(agent)) } } label: {
                        Label("\(agent.title) · \(agent.status)", systemImage: "person.crop.circle")
                    }.disabled(agent.nativeSessionID == nil)
                }
            } label: {
                chip(FirstMateCountText.phrase(agents.count, "agent"), systemImage: "person.2")
            }
            .disabled(agents.isEmpty)
            .accessibilityIdentifier("first-mate-visit-agents-\(visit.id)")
            Menu {
                ForEach(documents) { document in
                    Button { Task { await store.open(.document(document)) } } label: {
                        Label(document.title, systemImage: "doc.text")
                    }
                }
            } label: {
                chip(FirstMateCountText.phrase(documents.count, "document"), systemImage: "doc.text")
            }
            .disabled(documents.isEmpty)
            .accessibilityIdentifier("first-mate-visit-documents-\(visit.id)")
        }
        .menuStyle(.button)
        .buttonStyle(.herdrPlain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func chip(_ title: String, systemImage: String) -> some View {
        let palette = FirstMatePalette(scheme: scheme)
        return HStack(spacing: 6) {
            Image(systemName: systemImage)
                .herdrFont(size: 12)
                .foregroundStyle(palette.iconTint)
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 22)
        .background(palette.chipFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(.rect)
    }
}
