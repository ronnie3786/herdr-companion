import SwiftUI

/// Chooses an owner only. The standard review-team form follows dismissal,
/// and still requires the person's separate Add or Start action.
struct HomeReviewHostPicker: View {
    let request: HomeReviewPreparation
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose a review machine").herdrFont(.title2, weight: .semibold)
            Text("Prepare \(request.pullRequest.label) on the machine you choose.")
                .herdrFont(.callout).foregroundStyle(HerdrTheme.secondaryText)
            let machines = HomeRouting.availableReviewMachines(model: model)
            if machines.isEmpty {
                ContentUnavailableView("No review machine configured", systemImage: "desktopcomputer",
                    description: Text("Add a companion in Settings → Machines, then open this request again."))
            } else {
                ForEach(machines) { machine in
                    Button {
                        HomeRouting.chooseReviewHost(machine.id, request: request, model: model, shell: shell)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                            Text(machine.name)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(HerdrTheme.secondaryText)
                        }
                        .padding(12).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home-review-host-\(machine.id)")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    shell.homeReviewPreparationSelection = nil
                    shell.homeReviewPreparation = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 460)
        .foregroundStyle(HerdrTheme.primaryText)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("home-review-host-picker")
    }
}
