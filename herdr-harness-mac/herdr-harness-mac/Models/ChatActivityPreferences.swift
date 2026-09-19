import Foundation

enum ChatActivityPreferences {
    /// Shared by the main Pi transcript and the HUD. Keep the default false so
    /// existing installs preserve their current transcript presentation until
    /// the operator explicitly opts in.
    static let groupAllClankingActivityKey = "groupAllClankingActivity"
    static let defaultGroupAllClankingActivity = false
}
