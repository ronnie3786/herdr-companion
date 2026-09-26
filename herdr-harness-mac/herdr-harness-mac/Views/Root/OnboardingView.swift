import SwiftUI

struct OnboardingView: View {
    @Bindable var model: HerdrAppModel
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    brand
                    promise
                    connectionCard
                    demoButton
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(HerdrTheme.text)
    }

    private var brand: some View {
        HStack(spacing: 14) {
            HerdrBrandMark(size: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("herdr")
                    .herdrFont(size: HerdrTheme.TextSize.title, weight: .semibold)
                Text("Your agents, within reach")
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
        }
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Know where to look.")
                .herdrFont(size: HerdrTheme.TextSize.title, weight: .semibold)
            Text("Move from workspace to pane to live agent in seconds. Herdr keeps the terminals real; this app keeps the decisions close.")
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .lineSpacing(8)
                .foregroundStyle(HerdrTheme.proseText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                Label("Connect to your Mac", systemImage: "macbook.and.iphone")
                    .herdrFont(size: HerdrTheme.TextSize.reading, weight: .semibold)

                TextField("https://your-mac.example.test", text: $model.serverURLString)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .url)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .token }
                    .textFieldStyle(.plain)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .padding(.horizontal, 10)
                    .frame(minHeight: HerdrTheme.ControlHeight.row)
                    .herdrField(focused: focusedField == .url)

                SecureField("Pairing token", text: $model.apiToken)
                    .textContentType(.password)
                    .focused($focusedField, equals: .token)
                    .submitLabel(.go)
                    .onSubmit(model.connect)
                    .textFieldStyle(.plain)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .padding(.horizontal, 10)
                    .frame(minHeight: HerdrTheme.ControlHeight.row)
                    .herdrField(focused: focusedField == .token)

                Button("Connect", systemImage: "bolt.horizontal.circle.fill", action: model.connect)
                    .buttonStyle(HerdrButtonStyle(kind: .primary, height: HerdrTheme.ControlHeight.row))
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Label("Use localhost when Herdr runs on this Mac, or the private HTTPS URL from tailscale serve status for another Mac. The token stays in Keychain.", systemImage: "lock.shield")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You can add more machines later in Settings.")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
            .padding(16)
        }
    }

    private var demoButton: some View {
        Button("Explore with live-looking demo data", systemImage: "sparkles", action: model.useDemo)
            .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.row))
            .frame(maxWidth: .infinity)
            .accessibilityHint("Opens the app without connecting to a Mac")
    }
}

private extension OnboardingView {
    enum Field: Hashable {
        case url
        case token
    }
}
