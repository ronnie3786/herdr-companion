import Foundation
import Observation

/// Persists the custom HUD folder choices on this Mac, scoped by companion
/// machine id. The values are path strings, not local URLs: a remote machine
/// must receive its own path verbatim.
@MainActor
@Observable
final class HerdrHudWorkingFolderStore {
    static let defaultsKey = "herdr.hud.workingFolders.v1"
    private static let historyDefaultsKey = "herdr.hud.workingFolderHistory.v1"

    @ObservationIgnored private let userDefaults: UserDefaults
    private(set) var pathsByMachine: [String: [String]]
    @ObservationIgnored private var rememberedPathsByMachine: [String: [String: String]]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        pathsByMachine = Self.load(from: userDefaults)
        rememberedPathsByMachine = Self.loadHistory(from: userDefaults)
    }

    func customFolders(for machineID: String) -> [HerdrHudWorkingFolder] {
        pathsByMachine[machineID, default: []].compactMap { path in
            guard let normalized = HerdrHudWorkingFolder.normalizedPath(path),
                  normalized != HerdrHudWorkingFolder.homePath else {
                return nil
            }
            return HerdrHudWorkingFolder(path: normalized)
        }
    }

    @discardableResult
    func add(path rawPath: String, for machineID: String) throws -> HerdrHudWorkingFolder {
        guard !machineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HerdrHudWorkingFolderError.invalidMachine
        }
        guard let path = HerdrHudWorkingFolder.normalizedPath(rawPath) else {
            throw HerdrHudWorkingFolderError.invalidPath
        }
        guard path != HerdrHudWorkingFolder.homePath else {
            throw HerdrHudWorkingFolderError.homeIsBuiltIn
        }

        var paths = pathsByMachine[machineID, default: []]
        if !paths.contains(path) {
            paths.append(path)
            pathsByMachine[machineID] = paths
            persist()
        }
        return HerdrHudWorkingFolder(path: path)
    }

    func rememberedFolder(for machineID: String, chatID: String) -> HerdrHudWorkingFolder? {
        guard let path = rememberedPathsByMachine[machineID]?[chatID],
              let normalized = HerdrHudWorkingFolder.normalizedPath(path)
        else { return nil }
        return HerdrHudWorkingFolder(path: normalized)
    }

    func remember(folder: HerdrHudWorkingFolder, for machineID: String, chatID: String) {
        guard !machineID.isEmpty, !chatID.isEmpty else { return }
        if folder.isHome {
            rememberedPathsByMachine[machineID]?.removeValue(forKey: chatID)
            if rememberedPathsByMachine[machineID]?.isEmpty == true {
                rememberedPathsByMachine.removeValue(forKey: machineID)
            }
        } else {
            var paths = rememberedPathsByMachine[machineID, default: [:]]
            paths[chatID] = folder.path
            rememberedPathsByMachine[machineID] = paths
        }
        persistHistory()
    }

    @discardableResult
    func remove(path rawPath: String, for machineID: String) -> Bool {
        guard let path = HerdrHudWorkingFolder.normalizedPath(rawPath),
              path != HerdrHudWorkingFolder.homePath,
              var paths = pathsByMachine[machineID],
              let index = paths.firstIndex(of: path)
        else { return false }

        paths.remove(at: index)
        if paths.isEmpty {
            pathsByMachine.removeValue(forKey: machineID)
        } else {
            pathsByMachine[machineID] = paths
        }
        persist()
        return true
    }

    private func persist() {
        let nonEmpty = pathsByMachine.filter { !$0.value.isEmpty }
        if nonEmpty.isEmpty {
            userDefaults.removeObject(forKey: Self.defaultsKey)
        } else {
            userDefaults.set(nonEmpty, forKey: Self.defaultsKey)
        }
    }

    private func persistHistory() {
        let nonEmpty = rememberedPathsByMachine.filter { !$0.value.isEmpty }
        if nonEmpty.isEmpty {
            userDefaults.removeObject(forKey: Self.historyDefaultsKey)
        } else {
            userDefaults.set(nonEmpty, forKey: Self.historyDefaultsKey)
        }
    }

    private static func load(from userDefaults: UserDefaults) -> [String: [String]] {
        guard let stored = userDefaults.dictionary(forKey: Self.defaultsKey) else { return [:] }
        var result: [String: [String]] = [:]
        for (machineID, value) in stored {
            guard !machineID.isEmpty, let paths = value as? [String] else { continue }
            var unique: [String] = []
            for path in paths {
                guard let normalized = HerdrHudWorkingFolder.normalizedPath(path),
                      normalized != HerdrHudWorkingFolder.homePath,
                      !unique.contains(normalized)
                else { continue }
                unique.append(normalized)
            }
            if !unique.isEmpty { result[machineID] = unique }
        }
        return result
    }

    private static func loadHistory(from userDefaults: UserDefaults) -> [String: [String: String]] {
        guard let stored = userDefaults.dictionary(forKey: Self.historyDefaultsKey) else { return [:] }
        var result: [String: [String: String]] = [:]
        for (machineID, value) in stored {
            guard !machineID.isEmpty, let entries = value as? [String: String] else { continue }
            var paths: [String: String] = [:]
            for (chatID, rawPath) in entries {
                guard !chatID.isEmpty,
                      let path = HerdrHudWorkingFolder.normalizedPath(rawPath),
                      path != HerdrHudWorkingFolder.homePath
                else { continue }
                paths[chatID] = path
            }
            if !paths.isEmpty { result[machineID] = paths }
        }
        return result
    }
}
