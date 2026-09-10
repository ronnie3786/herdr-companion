import Foundation

/// A wall-clock phase, not time since a bubble was mounted or fetched metadata.
/// Recreated and newly revealed bubbles immediately join the current interval.
enum HerdrHudSessionMetadataCycle {
    static let epoch = Date(timeIntervalSince1970: 0)
    static let interval: TimeInterval = 5

    static func showsModel(at date: Date) -> Bool {
        floor(date.timeIntervalSince(epoch) / interval).truncatingRemainder(dividingBy: 2) == 0
    }
}
