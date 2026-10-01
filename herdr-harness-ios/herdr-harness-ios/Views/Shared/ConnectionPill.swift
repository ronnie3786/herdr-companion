import SwiftUI

struct ConnectionPill: View {
    let state: ConnectionState

    var body: some View {
        // Not a Label: inside a Form row a Label takes the row's icon column,
        // which left a tall empty gap under the Settings Server row.
        HStack(spacing: 6) {
            Image(systemName: state.symbol)
            Text(state.title)
        }
        .font(.caption.monospaced().bold())
        .foregroundStyle(state.color)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Server \(state.title)")
    }
}
