import SwiftUI

extension EnvironmentValues {
    @Entry var homeActionsEnabled = false
}

extension HomeCommand {
    var isNavigation: Bool { if case .open = self { true } else { false } }
}
