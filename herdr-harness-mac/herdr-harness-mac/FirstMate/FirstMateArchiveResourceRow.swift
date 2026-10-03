import SwiftUI

struct FirstMateArchiveResourceRow: View {
    @Binding var choice: FirstMateArchiveChoice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if choice.resource.canDelete {
                Toggle("Delete \(choice.resource.title.lowercased())", isOn: $choice.delete)
                    .labelsHidden().toggleStyle(.checkbox)
                    .accessibilityIdentifier("archive-resource-\(choice.id)")
            } else {
                Image(systemName: "lock.fill").foregroundStyle(HerdrTheme.secondaryText)
                    .frame(width: 14, height: 16)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(choice.resource.title).herdrFont(size: 13, weight: .medium)
                    Spacer()
                    Text(choice.resource.canDelete ? size : "Protected")
                        .herdrFont(size: 12, weight: .medium).monospacedDigit()
                        .foregroundStyle(choice.resource.canDelete ? HerdrTheme.text : HerdrTheme.success)
                }
                Text(choice.resource.path).herdrFont(size: 11, monospaced: true)
                    .lineLimit(1).truncationMode(.middle).help(choice.resource.path)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Text(choice.resource.reason).herdrFont(size: 11)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }.textSelection(.enabled)
        }
        .padding(14)
    }

    private var size: String {
        choice.resource.estimatedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unknown"
    }
}
