import SwiftUI

struct ToastView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Label(message, systemImage: "checkmark.circle.fill")
                .herdrFont(.subheadline, weight: .medium)
                .foregroundStyle(HerdrTheme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(HerdrTheme.elevated, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(HerdrTheme.separator, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
