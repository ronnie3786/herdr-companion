import SwiftUI
import UIKit

/// Saved pull request links, as on the Mac Overview: title, address, Open and Copy.
struct FirstMatePullRequestsCard: View {
    let links: [FirstMateLink]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 12, weight: .semibold)).foregroundStyle(HerdrTheme.iconTint)
                HerdrMicroLabel(text: "Pull requests", count: links.count)
            }
            ForEach(links) { link in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 14, weight: .semibold)).foregroundStyle(HerdrTheme.signal)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.title).herdrFont(.subheadline, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.address(link.url)).herdrFont(.caption).foregroundStyle(HerdrTheme.tertiaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Button("Open") { if let url = URL(string: link.url) { openURL(url) } }
                        .buttonStyle(HerdrButtonStyle(kind: .outline))
                        .accessibilityLabel("Open \(link.title)")
                    Button { UIPasteboard.general.string = link.url } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(HerdrButtonStyle(kind: .outline))
                        .accessibilityLabel("Copy \(link.title) link")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .herdrCard()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-pull-requests")
    }

    static func address(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        return host + components.path
    }
}
