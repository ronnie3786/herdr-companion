import AppKit
import SwiftUI

struct ResponseBriefDetailSelection: Identifiable {
    enum Content {
        case full
        case lines(start: Int, end: Int)
    }

    let id = UUID()
    let title: String
    let source: String
    let content: Content
}

struct ResponseBriefDetailView: View {
    let selection: ResponseBriefDetailSelection
    @Environment(\.dismiss) private var dismiss
    @State private var showsRaw = false

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if showsRaw {
                        Text(displayedSource)
                            .herdrFont(.body, monospaced: true)
                            .textSelection(.enabled)
                    } else {
                        PiMarkdownMessageView(
                            source: displayedSource,
                            isStreaming: false,
                            id: "response-brief-detail-\(selection.id)",
                            detectsPaneLinks: true
                        )
                    }
                }
                .frame(maxWidth: HerdrTheme.readingWidth, alignment: .leading)
                .padding(HerdrTheme.pagePadding)
            }
            .foregroundStyle(HerdrTheme.text)
            .background(HerdrTheme.graphite)
            .navigationTitle(selection.title)
            .toolbar {
                ToolbarItemGroup {
                    Toggle("Raw source", isOn: $showsRaw)
                    Button("Copy exact source", systemImage: "doc.on.doc", action: copySource)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("Done", action: dismiss.callAsFunction)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .accessibilityIdentifier("response-brief-detail")
    }

    private var displayedSource: String {
        switch selection.content {
        case .full:
            return selection.source
        case let .lines(start, end):
            let lines = ResponseBriefSourceLines.split(selection.source)
            guard start >= 1, end >= start, end <= lines.count else { return selection.source }
            return lines[(start - 1)...(end - 1)].joined(separator: "\n")
        }
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedSource, forType: .string)
    }
}
