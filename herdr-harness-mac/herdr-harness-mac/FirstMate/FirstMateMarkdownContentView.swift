import SwiftUI

struct FirstMateMarkdownContentView: View {
    private let blocks: [PiMarkdownBlock]

    init(source: String) {
        blocks = PiMarkdownDocumentCache.shared.blocks(for: source)
    }

    @Environment(\.firstMateMarkdownDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 8 : HerdrProse.blockSpacing) {
            ForEach(blocks) { block in
                FirstMateMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
