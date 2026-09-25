import Foundation

/// Which First Mate hosts a mobile browsing surface displays.
///
/// This is a browsing and filtering scope only. It is never a mutation or
/// creation destination: opening a feature, messaging it, archiving it, or
/// loading its workflow resources always uses the one machine that owns the
/// feature. Keeping the two concepts separate is what lets All Machines exist
/// without broadcasting commands to every companion.
enum FirstMateMachineScope: Hashable, Sendable {
    case all
    case machine(String)

    /// Whether a machine belongs to this scope.
    func includes(machineID: String) -> Bool {
        switch self {
        case .all: true
        case .machine(let selected): selected == machineID
        }
    }

    /// Narrows a persisted choice to the roster that exists right now.
    ///
    /// A missing or removed host resolves to ``all`` rather than silently
    /// falling through to the first remaining machine, which could send an
    /// action to a host the person never chose.
    static func resolved(_ selection: Self?, availableMachineIDs: [String]) -> Self {
        guard case .machine(let machineID) = selection,
              availableMachineIDs.contains(machineID) else { return .all }
        return .machine(machineID)
    }
}

/// Reads and writes the versioned First Mate scope preference.
///
/// The value is tagged and versioned — `v1:all` or `v1:machine:<id>` — so the
/// All Machines case can never collide with a real machine ID. Anything that
/// is absent, malformed, or written by a future revision decodes to All
/// Machines instead of guessing.
///
/// The legacy `herdr.firstMate.machine` key is deliberately neither read nor
/// written here. An upgrade that only has that key opens on All Machines until
/// the person makes an explicit choice, which is then recorded under the new
/// key while the old value stays untouched.
struct FirstMateScopePreference {
    static let key = "herdr.firstMate.scope.v1"
    static let legacyMachineKey = "herdr.firstMate.machine"
    static let allTag = "v1:all"
    static let machineTag = "v1:machine:"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved choice, or ``FirstMateMachineScope/all`` when no valid
    /// versioned preference exists.
    var scope: FirstMateMachineScope {
        Self.decode(defaults.string(forKey: Self.key)) ?? .all
    }

    func load() -> FirstMateMachineScope { scope }

    /// The saved choice narrowed to the machines in `availableMachineIDs`.
    func loadResolved(availableMachineIDs: [String]) -> FirstMateMachineScope {
        FirstMateMachineScope.resolved(scope, availableMachineIDs: availableMachineIDs)
    }

    /// Remembers an explicit choice, including an explicit All Machines.
    func save(_ scope: FirstMateMachineScope) {
        defaults.set(Self.encode(scope), forKey: Self.key)
    }

    static func encode(_ scope: FirstMateMachineScope) -> String {
        switch scope {
        case .all: allTag
        case .machine(let machineID): machineTag + machineID
        }
    }

    static func decode(_ value: String?) -> FirstMateMachineScope? {
        guard let value else { return nil }
        if value == allTag { return .all }
        guard value.hasPrefix(machineTag) else { return nil }
        let machineID = String(value.dropFirst(machineTag.count))
        return machineID.isEmpty ? nil : .machine(machineID)
    }
}
