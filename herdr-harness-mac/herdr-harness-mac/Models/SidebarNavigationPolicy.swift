import Foundation

enum SidebarMachinePickerPresentation: Equatable {
    case hidden
    case segmented
    case menu

    static func presentation(machineCount: Int) -> Self {
        switch machineCount {
        case ...0: .hidden
        case 1...3: .segmented
        default: .menu
        }
    }
}
