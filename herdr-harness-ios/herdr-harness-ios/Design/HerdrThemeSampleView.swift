#if DEBUG
import SwiftUI

/// Synthetic, launch-argument-only palette fixture. Never contacts a companion.
struct HerdrThemeSampleView: View {
    var body: some View {
        ScrollView {
            HerdrThemeSampleContent()
        }
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                HerdrGlassBackground(level: HerdrTheme.Glass.pane)
                HerdrHazeBand()
            }
            .ignoresSafeArea()
        }
        .herdrFirstMateChrome()
        .accessibilityIdentifier("theme-dusk-sample")
    }
}

struct HerdrThemeSampleContent: View {
    @State private var draft = ""
    @State private var selection = "Overview"
    @State private var sent = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                FirstMateFaceOrb(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("First Mate").herdrFont(.title2, weight: .semibold)
                    Text("Dusk glass · theme foundation")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)

            HerdrTabs(selection: $selection, tabs: ["Overview", "Agents", "Documents"].map {
                .init(value: $0, title: $0)
            }, style: .underline, accessibilityLabel: "Theme sample tabs")

            VStack(alignment: .leading, spacing: 10) {
                HerdrMicroLabel(text: "Reading", count: 4)
                Text("Primary · a clear heading").foregroundStyle(HerdrTheme.primaryText)
                Text("Prose · one place to follow your features.").foregroundStyle(HerdrTheme.proseText)
                Text("Secondary · your team is moving.").foregroundStyle(HerdrTheme.secondaryText)
                Text("Tertiary · synced just now.").foregroundStyle(HerdrTheme.tertiaryText)
            }
            .herdrFont(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .herdrCard()

            HStack(spacing: 12) {
                FirstMateEmojiDisc(emoji: "🧾", size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Receipt export").herdrFont(.callout, weight: .semibold)
                    Text("Review the retained evidence.")
                        .herdrFont(.subheadline)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                    Text("Blocked").herdrFont(.footnote, weight: .semibold).foregroundStyle(HerdrTheme.alert)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .herdrRowBackground(selected: true)
            .accessibilityElement(children: .combine)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { statuses }
                VStack(alignment: .leading, spacing: 12) { statuses }
            }

            Text(sent ? "Direction received." : "The build is ready for your review.")
                .font(HerdrProse.font(.bubble))
                .lineSpacing(HerdrProse.lineSpacing(.bubble))
                .foregroundStyle(HerdrTheme.proseText)
                .padding(14)
                .herdrCard(radius: HerdrTheme.Radius.bubble, fill: HerdrTheme.codeFill, outline: HerdrTheme.hairline)
                .accessibilityIdentifier("theme-sample-bubble")

            TextField("", text: $draft, prompt: Text("Message").foregroundStyle(HerdrTheme.tertiaryText), axis: .vertical)
                .herdrFont(.body)
                .lineLimit(1...7)
                .focused($focused)
                .padding(14)
                .herdrField(focused: focused)
                .accessibilityLabel("Sample message")
                .accessibilityIdentifier("theme-sample-field")

            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Synthetic data · no agents launched")
                if reduceMotion { Text("Reduce Motion on").accessibilityIdentifier("theme-reduce-motion") }
                if reduceTransparency { Text("Reduce Transparency on").accessibilityIdentifier("theme-reduce-transparency") }
            }
            .herdrFont(.caption2)
            .foregroundStyle(HerdrTheme.tertiaryText)
        }
        .foregroundStyle(HerdrTheme.primaryText)
        .padding(20)
    }

    private var statuses: some View {
        Group {
            Text("Your turn").foregroundStyle(HerdrTheme.attentionBadge).herdrPill()
            Text("Ready").foregroundStyle(HerdrTheme.signal).herdrPill()
            Text("Building").foregroundStyle(HerdrTheme.working).firstMateBreathing()
        }
        .herdrFont(.footnote, weight: .semibold)
    }

    private var actions: some View {
        Group {
            Button("Send direction") { sent = true; draft = "" }
                .buttonStyle(HerdrButtonStyle(kind: .primary))
                .accessibilityIdentifier("theme-sample-send")
            Button("Open readout") { selection = "Overview" }
                .buttonStyle(HerdrButtonStyle(kind: .outline, height: 36))
        }
    }
}
#endif
