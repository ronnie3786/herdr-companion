import Foundation
import Observation

/// Stable root-owned Home presentation. Source stores retain all operational ownership.
@MainActor @Observable
final class HomeStore {
    private(set) var snapshot = HomeSnapshot()
    private(set) var selectedFocusID: String?
    private(set) var previousVisit: Date?
    private(set) var status: String?
    private(set) var canUndoSnooze = false
    var search = "" { didSet { if search != oldValue { rebuild(now: clock()) } } }
    var recapExpanded: Bool {
        didSet {
            guard recapExpanded != oldValue else { return }
            preferences.recapExpanded = recapExpanded
            persist()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var preferences: HomeLocalPreferences
    @ObservationIgnored private var source = HomeSnapshot()
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var undoSnooze: (id: String, choice: HomeEvidenceChoice)?
    @ObservationIgnored private var isVisiting = false
    private static let preferencesKey = "herdr.home.presentation.v1"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = now
        var stored = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(HomeLocalPreferences.self, from: $0) }
            .flatMap { $0.version == 1 ? $0 : nil } ?? HomeLocalPreferences()
        stored.prune(now: now())
        preferences = stored
        recapExpanded = stored.recapExpanded
        previousVisit = stored.lastVisit
    }

    var selectedFocus: HomeFocusItem? {
        snapshot.focus.first { $0.id == selectedFocusID }
    }

    var snoozedCount: Int {
        source.focus.filter { item in
            guard let choice = preferences.snoozes[item.id] else { return false }
            return choice.fingerprint == item.fingerprint && (choice.expiresAt ?? .distantPast) > clock()
        }.count
    }

    func beginVisit(now: Date? = nil) {
        guard !isVisiting else { return }
        isVisiting = true
        previousVisit = preferences.lastVisit
        preferences.lastVisit = now ?? clock()
        persist()
    }

    func endVisit() { isVisiting = false }

    func receive(_ snapshot: HomeSnapshot, now: Date? = nil) {
        let instant = now ?? clock()
        source = snapshot
        for id in snapshot.focus.map(\.id) + snapshot.radar.map(\.id) {
            if instant.timeIntervalSince(preferences.lastSeen[id] ?? .distantPast) >= 3_600 {
                preferences.lastSeen[id] = instant
            }
        }
        preferences.prune(now: instant)
        rebuild(now: instant)
        persist()
    }

    func selectFocus(_ id: String) {
        guard snapshot.focus.contains(where: { $0.id == id }) else { return }
        selectedFocusID = id
    }

    func skip() {
        guard let id = selectedFocusID, snapshot.focus.count > 1,
              let index = snapshot.focus.firstIndex(where: { $0.id == id }) else { return }
        let next = snapshot.focus[(index + 1) % snapshot.focus.count].id
        order.removeAll { $0 == id }
        order.append(id)
        selectedFocusID = next
        rebuild(now: clock())
    }

    func snooze(_ id: String, now: Date? = nil) {
        guard let item = source.focus.first(where: { $0.id == id }), !item.isIdea else { return }
        let instant = now ?? clock()
        let expires = instant.addingTimeInterval(60 * 60)
        let choice = HomeEvidenceChoice(fingerprint: item.fingerprint, expiresAt: expires)
        preferences.snoozes[id] = choice
        preferences.lastSeen[id] = instant
        undoSnooze = (id, choice)
        canUndoSnooze = true
        status = "Snoozed until \(expires.formatted(date: .omitted, time: .shortened))."
        rebuild(now: instant)
        persist()
    }

    func undoLastSnooze() {
        guard let undo = undoSnooze else { return }
        if preferences.snoozes[undo.id] == undo.choice { preferences.snoozes[undo.id] = nil }
        undoSnooze = nil
        canUndoSnooze = false
        status = "Snooze undone."
        rebuild(now: clock())
        selectFocus(undo.id)
        persist()
    }

    func dismissRadar(_ id: String, now: Date? = nil) {
        guard let item = source.radar.first(where: { $0.id == id }) else { return }
        let instant = now ?? clock()
        preferences.dismissals[id] = HomeEvidenceChoice(fingerprint: item.fingerprint)
        preferences.lastSeen[id] = instant
        rebuild(now: instant)
        persist()
    }

    func refreshLocalTime(now: Date? = nil) {
        let instant = now ?? clock()
        preferences.prune(now: instant)
        if let undo = undoSnooze, (undo.choice.expiresAt ?? .distantPast) <= instant {
            undoSnooze = nil
            canUndoSnooze = false
            status = nil
        }
        rebuild(now: instant)
        persist()
    }

    func showStatus(_ text: String?) { status = text }

    private func rebuild(now: Date) {
        let oldIDs = snapshot.focus.map(\.id)
        let oldIndex = oldIDs.firstIndex(of: selectedFocusID ?? "") ?? 0
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }
        var visible = source
        let eligible = source.focus.filter { item in
            let hidden = preferences.snoozes[item.id].map {
                $0.fingerprint == item.fingerprint && ($0.expiresAt ?? .distantPast) > now
            } ?? false
            return !hidden && matches("\(item.title) \(item.reason) \(item.body.plainText)")
        }
        let available = Set(eligible.map(\.id))
        // Preserve order through unrelated source refreshes; append genuinely new evidence.
        order = order.filter { available.contains($0) }
        let existing = Set(order)
        order.append(contentsOf: eligible.map(\.id).filter { !existing.contains($0) })
        let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        visible.focus = order.compactMap { byID[$0] }
        visible.radar = source.radar.filter { item in
            preferences.dismissals[item.id]?.fingerprint != item.fingerprint && matches(item.body.plainText)
        }
        visible.chats = source.chats.filter { matches("\($0.title) \($0.location) \($0.reason) \($0.quote)") }
        visible.recap = source.recap.filter { matches($0.body.plainText) }
        if !query.isEmpty { visible.summary = source.summary.filter { matches($0.plainText) } }
        if !available.contains(selectedFocusID ?? "") {
            selectedFocusID = visible.focus.isEmpty ? nil : visible.focus[min(oldIndex, visible.focus.count - 1)].id
        }
        if visible != snapshot { snapshot = visible }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(preferences) else { return }
        // Avoid a preferences write on every identical polling response.
        if defaults.data(forKey: Self.preferencesKey) != data { defaults.set(data, forKey: Self.preferencesKey) }
    }
}
