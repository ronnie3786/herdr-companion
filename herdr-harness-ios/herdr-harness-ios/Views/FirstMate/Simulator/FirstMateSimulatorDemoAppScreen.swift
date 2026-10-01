import SwiftUI

/// Demo mode's stand-in for a running simulator's picture: a plain iOS list
/// app drawn once. Receipts uses the shared demo screen (as on the Mac);
/// Review search gets a Reviews list, as in the iPad prototype. Synthetic.
struct FirstMateSimulatorDemoAppScreen: View {
    enum Kind: Hashable {
        case receipts
        case reviews
    }

    @MainActor private static var cache: [Kind: CGImage] = [:]

    @MainActor static func image(_ kind: Kind) -> CGImage? {
        switch kind {
        case .receipts:
            return FirstMateSimulatorDemo.screenImage()
        case .reviews:
            if let image = cache[kind] { return image }
            let renderer = ImageRenderer(content: FirstMateSimulatorDemoAppScreen().frame(width: 402, height: 874))
            renderer.scale = 2
            cache[kind] = renderer.cgImage
            return cache[kind]
        }
    }

    private let rows: [(String, String, String, String)] = [
        ("magnifyingglass", "Index rebuild on launch", "PR #214 · note", "2 s"),
        ("checkmark.seal.fill", "Seven reviewers passed", "PR #214", "All"),
        ("testtube.2", "SearchUITests", "CI · passed", "41 s"),
        ("doc.text", "Review roll-up", "Document", "v2"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("9:41").font(.system(size: 17, weight: .semibold))
                Spacer()
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .frame(height: 62)
            Text("Reviews")
                .font(.system(size: 34, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 6)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search review evidence")
                Spacer()
            }
            .font(.system(size: 17))
            .foregroundStyle(Color(white: 0.55))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(white: 0.93), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Text("RESULTS")
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.45))
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.93, green: 0.92, blue: 1))
                            .frame(width: 36, height: 36)
                            .overlay { Image(systemName: row.0).foregroundStyle(Color(red: 0.36, green: 0.33, blue: 0.86)) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.1).font(.system(size: 17, weight: .medium))
                            Text(row.2).font(.system(size: 13)).foregroundStyle(Color(white: 0.5))
                        }
                        Spacer()
                        Text(row.3).font(.system(size: 17)).monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 62)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .background(.white, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            Spacer()
            Text("Open the sidebar")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(red: 0.36, green: 0.33, blue: 0.86), in: .rect(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 44)
        }
        .foregroundStyle(.black)
        .background(Color(white: 0.96))
        .environment(\.colorScheme, .light)
    }
}
