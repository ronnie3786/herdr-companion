import SwiftUI

struct FirstMateDocumentContentView: View {
    private let blocks: [PiMarkdownBlock]

    init(source: String) {
        blocks = PiMarkdownParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                FirstMateMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
