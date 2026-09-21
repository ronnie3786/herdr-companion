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

/// Sidebar-only presentation of the configured machines for the segmented picker.
///
/// Each segment keeps the original machine ID and full configured name so
/// selection, persistence, and tooltips continue to refer to the real record.
/// Optional labels and order come only from the private configuration roster.
enum SidebarMachineSegmentPresentation {
    struct Segment: Equatable, Identifiable, Sendable {
        /// Original machine identifier from the saved roster.
        let id: String
        /// Original full configured name, retained for tooltips.
        let name: String
        /// Configured compact label, or the unchanged full name.
        let title: String
    }

    /// Explicitly ordered machines precede unordered machines. Equal orders and
    /// unordered machines retain their original saved-roster order. Duplicate
    /// labels remain distinct because identity always uses the machine ID.
    static func segments(for machines: [HerdrMachine]) -> [Segment] {
        machines
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.sidebarOrder, rhs.element.sidebarOrder) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map { _, machine in
                Segment(
                    id: machine.id,
                    name: machine.name,
                    title: machine.sidebarLabel ?? machine.name
                )
            }
    }
}
