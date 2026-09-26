import SwiftUI

struct HerdrHudTranscriptErrorsView: View {
    let errorMessage: String?
    let promoteErrorMessage: String?
    let audioErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.alert)
            }
            if let promoteErrorMessage, !promoteErrorMessage.isEmpty {
                Text(promoteErrorMessage)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.alert)
            }
            if let audioErrorMessage, !audioErrorMessage.isEmpty {
                Text(audioErrorMessage)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.alert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
