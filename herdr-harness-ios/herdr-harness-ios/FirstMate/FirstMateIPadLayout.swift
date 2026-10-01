import CoreGraphics

/// How the iPad First Mates tab splits its width: the conversation list (or
/// its orb rail), the chat, and the inspector. The chat comes first. The
/// inspector opens on demand: landscape docks it as a column, portrait floats
/// it over the chat as a sheet unless the person pins it. The list folds to
/// the rail by itself when a docked inspector would leave the chat narrower
/// than `minimumChatWidth`.
struct FirstMateIPadLayout: Equatable {
    enum ListPreference: String, Equatable { case full, rail }
    enum Inspector: Equatable { case hidden, docked, floating }

    static let railWidth: CGFloat = 84
    static let minimumChatWidth: CGFloat = 560
    /// Below this the list and a docked inspector would crush the chat, so
    /// the inspector floats even when it was docked.
    static let minimumDockedChatWidth: CGFloat = 440
    static let minimumPinWidth: CGFloat = 900

    var isLandscape: Bool
    var showsRail: Bool
    /// The full list's width, kept while it shows as the rail so it can slide back.
    var listWidth: CGFloat
    var inspector: Inspector
    var inspectorWidth: CGFloat
    /// Portrait iPads wide enough to dock the inspector beside the chat.
    var canPin: Bool

    var leadingWidth: CGFloat { showsRail ? Self.railWidth : listWidth }
    var dockedInspectorWidth: CGFloat { inspector == .docked ? inspectorWidth : 0 }
    var inspectorOpen: Bool { inspector != .hidden }

    /// - Parameters:
    ///   - inspectorOpen: the person's last choice; nil follows the orientation (open in landscape).
    ///   - list: the person's last choice; nil lets the list fold when the chat needs the room.
    ///   - pinned: portrait only: dock the inspector instead of floating it.
    static func resolve(size: CGSize, inspectorOpen: Bool?, list: ListPreference?, pinned: Bool) -> FirstMateIPadLayout {
        let width = max(0, size.width)
        let landscape = size.width > size.height
        let listWidth: CGFloat = landscape ? (width >= 1300 ? 360 : 336) : (width >= 1000 ? 340 : 316)
        let open = inspectorOpen ?? landscape
        let canPin = !landscape && width >= minimumPinWidth
        let docked = landscape || (pinned && canPin)
        let dockedWidth: CGFloat = landscape && width >= 1300 ? 380 : 360
        let rail: Bool = switch list {
        case .rail: true
        case .full: false
        case nil: width - listWidth - (open && docked ? dockedWidth : 0) < minimumChatWidth
        }
        let floats = !docked || (!rail && width - listWidth - dockedWidth < minimumDockedChatWidth)
        let inspector: Inspector = !open ? .hidden : floats ? .floating : .docked
        let inspectorWidth = floats ? min(400, max(0, width - 140)) : dockedWidth
        return FirstMateIPadLayout(isLandscape: landscape, showsRail: rail, listWidth: listWidth,
                                   inspector: inspector, inspectorWidth: inspectorWidth, canPin: canPin)
    }
}
