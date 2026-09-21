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
/// Only the visible title is shortened, and the helper never reads roles, URLs,
/// or hostnames.
enum SidebarMachineSegmentPresentation {
    struct Segment: Equatable, Identifiable, Sendable {
        /// Original machine identifier from the roster.
        let id: String
        /// Original full configured name, retained for tooltips.
        let name: String
        /// Compact label shown in the sidebar segment.
        let title: String
    }

    /// Projects the roster into segments ordered Work, Dev, Studio, then
    /// unrecognized names in their original roster order. Matching is
    /// case-insensitive after trimming, and duplicate labels are never merged.
    static func segments(for machines: [HerdrMachine]) -> [Segment] {
        machines
            .enumerated()
            .map { offset, machine in
                let canonical = canonicalPresentation(for: machine.name)
                return RankedSegment(
                    rank: canonical?.rank ?? .unrecognized,
                    rosterIndex: offset,
                    segment: Segment(
                        id: machine.id,
                        name: machine.name,
                        title: canonical?.title ?? machine.name
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.rosterIndex < rhs.rosterIndex
            }
            .map(\.segment)
    }

    private struct RankedSegment {
        let rank: Rank
        let rosterIndex: Int
        let segment: Segment
    }

    private enum Rank: Int, Comparable {
        case work
        case dev
        case studio
        case unrecognized

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private static func canonicalPresentation(for name: String) -> (rank: Rank, title: String)? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "work mac", "work":
            return (Rank.work, "Work")
        case "devbox", "dev":
            return (Rank.dev, "Dev")
        case "local mac", "studio":
            return (Rank.studio, "Studio")
        default:
            return nil
        }
    }
}
