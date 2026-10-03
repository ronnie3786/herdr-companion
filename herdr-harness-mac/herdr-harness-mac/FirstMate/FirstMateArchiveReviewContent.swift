import SwiftUI

struct FirstMateArchiveReviewContent: View {
    @Bindable var model: FirstMateArchiveModel

    var body: some View {
        if let preview = model.preview {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield").foregroundStyle(HerdrTheme.success)
                    .font(.system(size: 17))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your history stays with you").herdrFont(size: 13, weight: .semibold)
                    Text("The full record is saved before cleanup. Find it in Search completed work.")
                        .herdrFont(size: 12).foregroundStyle(HerdrTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Text("Keep in this session").herdrFont(size: 14, weight: .semibold)
                HStack(spacing: 24) {
                    Toggle(isOn: $model.keepDocuments) {
                        HStack(spacing: 8) {
                            Label("Documents", systemImage: "doc.text")
                            Text("\(preview.documentCount)").foregroundStyle(HerdrTheme.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("first-mate-archive-keep-documents")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(isOn: $model.keepChat) {
                        HStack(spacing: 8) {
                            Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                            Text("\(preview.messageCount) messages").foregroundStyle(HerdrTheme.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("first-mate-archive-keep-chat")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.checkbox)
                .padding(14).background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
                Text("Unchecked copies move to the catalog, where you can still search and export them.")
                    .herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Resources to delete").herdrFont(size: 14, weight: .semibold)
                    Spacer()
                    Button("Keep all") {
                        for index in model.choices.indices { model.choices[index].delete = false }
                    }
                    .buttonStyle(.herdrPlain).foregroundStyle(HerdrTheme.accent)
                    .disabled(model.selectedCount == 0)
                }
                VStack(spacing: 0) {
                    if model.choices.isEmpty {
                        Label("No disposable resources found", systemImage: "checkmark.circle")
                            .foregroundStyle(HerdrTheme.secondaryText).padding(16)
                    }
                    ForEach($model.choices) { $choice in
                        FirstMateArchiveResourceRow(choice: $choice)
                            .herdrHairline(.bottom, color: HerdrTheme.rowDivider)
                    }
                }
                .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
                Label("Project folder, published builds, backups and unregistered files stay protected.", systemImage: "lock")
                    .herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
            }

            DisclosureGroup("What is saved and how cleanup works") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The catalog keeps your request, ticket reference, outcome, commits, links, verification, usage, and original documents and conversation. External files, attachments and agent transcripts stay in place.")
                    Text("Estimates use logical file sizes on the companion. Actual free space may differ. Cataloging text makes database space reusable but may not shrink its file.")
                    Text("Every deletion is checked again. Anything that becomes unsafe is kept with a reason. Unarchiving does not recreate deleted files.")
                }
                .herdrFont(size: 12).foregroundStyle(HerdrTheme.secondaryText)
                .padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(HerdrTheme.secondaryText)
            Picker("Reason (optional)", selection: $model.reason) {
                Text("No reason").tag(nil as FirstMateArchiveReason?)
                ForEach(FirstMateArchiveReason.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .foregroundStyle(HerdrTheme.secondaryText)
            if !preview.eligible {
                Label(preview.ineligibleReason ?? "This session is not eligible for cleanup.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(HerdrTheme.warning)
            }
        }
    }
}
