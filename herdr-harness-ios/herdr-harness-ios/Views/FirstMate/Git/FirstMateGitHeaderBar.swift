import SwiftUI

/// Done; "<feature> · Git" over "machine · checkout · path"; the checkout
/// picker (unless the cover is pinned to one checkout); Refresh.
struct FirstMateGitHeaderBar: View {
    let store: FirstMateGitStore
    let title: String
    let subtitle: String
    let compact: Bool
    let done: () -> Void
    let chooseCheckout: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Done", action: done)
                .herdrFont(size: 15, weight: .semibold, relativeTo: .body)
                .foregroundStyle(HerdrTheme.primaryText)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .herdrControlGlass(in: .capsule)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .contentShape(.rect)
                .buttonStyle(.herdrPlain)
                .accessibilityIdentifier("first-mate-git-done")
                .composerLayoutMeasurement(id: "first-mate-git-done")

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .herdrFont(size: 16, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(compact ? 2 : 1)
                Text(subtitle)
                    .herdrFont(size: 12, monospaced: true, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("first-mate-git-context")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if store.showsCheckoutPicker {
                checkoutPicker
            }

            Button {
                Task { await store.reload() }
            } label: {
                Label("Refresh Git", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(HerdrTheme.primaryText)
                    .symbolEffect(.rotate, options: .repeating, isActive: store.isRefreshing)
                    .herdrGlassCircle(38)
            }
            .buttonStyle(.herdrPlain)
            .disabled(store.isRefreshing)
            .accessibilityIdentifier("first-mate-git-refresh")
            .composerLayoutMeasurement(id: "first-mate-git-refresh")
        }
        .padding(.leading, compact ? 12 : 16)
        .padding(.trailing, compact ? 8 : 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .background { FirstMateGitSurface.bar.ignoresSafeArea(edges: .top) }
        .herdrHairline(.bottom)
        .composerLayoutMeasurement(id: "first-mate-git-header")
    }

    private var checkoutPicker: some View {
        let groups = store.catalog.map(FirstMateGitSelectionRules.pickerGroups) ?? (primary: [], other: [])
        let label = store.selectedCheckout?.title ?? "Choose checkout"
        return Menu {
            ForEach(groups.primary) { option($0) }
            if !groups.other.isEmpty {
                Menu("Other checkouts (\(groups.other.count))") {
                    ForEach(groups.other) { option($0) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HerdrTheme.secondaryText)
                if !compact {
                    Text(label)
                        .herdrFont(size: 13.5, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(HerdrTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // As wide as the title, up to 340 pt.
                        .frame(maxWidth: 340)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
            .padding(.horizontal, compact ? 12 : 14)
            .frame(height: 38)
            .herdrControlGlass(in: .capsule)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .disabled(store.isMutating)
        .accessibilityLabel("Git checkout")
        .accessibilityValue(label)
        .accessibilityHint("Choose a checkout: the feature branch, the project, or another agent’s checkout.")
        .accessibilityIdentifier("first-mate-git-checkout-picker")
        .composerLayoutMeasurement(id: "first-mate-git-checkout-picker")
    }

    private func option(_ checkout: FirstMateGitCheckout) -> some View {
        Button {
            chooseCheckout(checkout.id)
        } label: {
            if checkout.matches(store.selectedCheckoutID) {
                Label(checkout.title, systemImage: "checkmark")
            } else {
                Text(checkout.title)
            }
            Text(checkout.path)
        }
        .accessibilityIdentifier("first-mate-git-checkout-\(checkout.id)")
    }
}
