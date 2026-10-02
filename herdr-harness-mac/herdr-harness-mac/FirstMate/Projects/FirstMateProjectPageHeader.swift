import SwiftUI

struct FirstMateProjectPageHeader: View {
    let title: String
    let refresh: () -> Void
    var projects: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
            Spacer()
            if let projects {
                Button("Manage projects", systemImage: "folder", action: projects)
                    .buttonStyle(HerdrIconButtonStyle())
            }
            Button("Refresh machines", systemImage: "arrow.clockwise", action: refresh)
                .buttonStyle(HerdrIconButtonStyle())
        }
        .padding(.leading, 18).padding(.trailing, 8).herdrBar()
    }
}
