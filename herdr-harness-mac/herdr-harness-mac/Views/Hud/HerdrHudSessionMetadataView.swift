import SwiftUI

struct HerdrHudSessionMetadataView: View {
    let metadata: HerdrHudSessionMetadata
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsModel = true

    var body: some View {
        ZStack(alignment: .trailing) {
            if let label = metadata.label(showsModel: showsModel) {
                Text(label)
                    .herdrFont(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(showsModel)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(HerdrTheme.mist)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
        .help(metadata.accessibilitySummary)
        .accessibilityLabel(metadata.accessibilitySummary)
        .task(id: metadata.alternates) {
            showsModel = true
            guard metadata.alternates else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { showsModel.toggle() }
            }
        }
    }
}
