import SwiftUI

extension EnvironmentValues {
    @Entry var paneResponseLinkCatalog: PaneResponseLinkCatalog? = nil
    @Entry var detectsPaneResponseLinks = false
    @Entry var openResponsePane: (@MainActor (String) -> Void)? = nil
}

struct PaneResponseLinks: ViewModifier {
    @Bindable var model: HerdrAppModel
    let sourceMachineID: String?
    var openPane: (@MainActor (String) -> Void)? = nil
    @Environment(\.openResponsePane) private var openInMainWindow

    private var catalog: PaneResponseLinkCatalog {
        PaneResponseLinkCatalog(
            panes: model.workspaces.filter { model.canControl(machineID: $0.machineID) }.flatMap(\.panes),
            machines: model.machines, sourceMachineID: sourceMachineID
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(\.paneResponseLinkCatalog, catalog)
            .environment(\.openURL, OpenURLAction { url in
                // Resolve against live model data again at click time. A pane
                // may have closed, moved, or changed terminal since rendering.
                guard catalog.isPaneURL(url) else { return .systemAction }
                guard let target = catalog.target(for: url) else {
                    model.toastMessage = "That pane is no longer available on its machine."
                    return .handled
                }
                if let action = openPane ?? openInMainWindow {
                    action(target.scopedID)
                } else {
                    model.openPane(id: target.scopedID)
                }
                return .handled
            })
    }
}

extension View {
    func paneResponseLinks(
        model: HerdrAppModel, sourceMachineID: String?,
        openPane: (@MainActor (String) -> Void)? = nil
    ) -> some View {
        modifier(PaneResponseLinks(model: model, sourceMachineID: sourceMachineID, openPane: openPane))
    }
}
