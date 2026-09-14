import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("HUD working folders")
@MainActor
struct HerdrHudWorkingFolderTests {
    @Test("Custom folders persist independently for each machine")
    func persistsPerMachine() throws {
        let defaults = makeDefaults()
        let store = HerdrHudWorkingFolderStore(userDefaults: defaults)

        _ = try store.add(path: "/synthetic/studio/project", for: "studio")
        _ = try store.add(path: "/synthetic/studio/docs", for: "studio")
        _ = try store.add(path: "/synthetic/laptop/project", for: "laptop")

        #expect(store.customFolders(for: "studio").map(\.path) == [
            "/synthetic/studio/project", "/synthetic/studio/docs",
        ])
        #expect(store.customFolders(for: "laptop").map(\.path) == ["/synthetic/laptop/project"])
        #expect(store.customFolders(for: "unknown").isEmpty)
        store.remember(
            folder: HerdrHudWorkingFolder(path: "/synthetic/studio/project"),
            for: "studio",
            chatID: "chat-1"
        )

        let reloaded = HerdrHudWorkingFolderStore(userDefaults: defaults)
        #expect(reloaded.customFolders(for: "studio").map(\.path) == [
            "/synthetic/studio/project", "/synthetic/studio/docs",
        ])
        #expect(reloaded.customFolders(for: "laptop").map(\.path) == ["/synthetic/laptop/project"])
        #expect(reloaded.rememberedFolder(for: "studio", chatID: "chat-1")?.path == "/synthetic/studio/project")

        #expect(reloaded.remove(path: "/synthetic/studio/project", for: "studio"))
        #expect(reloaded.customFolders(for: "studio").map(\.path) == ["/synthetic/studio/docs"])
        #expect(!reloaded.remove(path: "/synthetic/studio/project", for: "studio"))
        #expect(reloaded.customFolders(for: "laptop").map(\.path) == ["/synthetic/laptop/project"])
    }

    @Test("Folder validation keeps home built in and rejects relative paths")
    func validatesPaths() throws {
        let store = HerdrHudWorkingFolderStore(userDefaults: makeDefaults())

        #expect(throws: HerdrHudWorkingFolderError.self) {
            try store.add(path: "project", for: "studio")
        }
        #expect(throws: HerdrHudWorkingFolderError.self) {
            try store.add(path: "~", for: "studio")
        }
        #expect(throws: HerdrHudWorkingFolderError.self) {
            try store.add(path: "/synthetic/with\0null", for: "studio")
        }
        #expect(throws: HerdrHudWorkingFolderError.self) {
            try store.add(path: "/synthetic/project", for: "")
        }
    }

    @Test("A fresh composer can choose a saved folder before machine selection is persisted")
    func selectsSavedFolderBeforeMachineSelection() throws {
        let defaults = makeDefaults()
        let store = HerdrHudWorkingFolderStore(userDefaults: defaults)
        _ = try store.add(path: "/synthetic/studio/project", for: "studio")
        let session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-hud-selection.json"),
            workingFolderStore: store
        )

        #expect(session.selectedMachineID == nil)
        #expect(session.selectWorkingFolder(path: "/synthetic/studio/project", for: "studio"))
        #expect(session.selectedMachineID == "studio")
        #expect(session.selectedWorkingFolder.path == "/synthetic/studio/project")
    }

    @Test("A remote folder is displayed and sent without local path expansion")
    func remotePathsRemainOpaque() {
        let local = HerdrMachine(id: "local", name: "This Mac", urlString: "http://localhost:9092")
        let remote = HerdrMachine(id: "remote", name: "Remote Mac", urlString: "https://remote.example.invalid")
        let localHome = FileManager.default.homeDirectoryForCurrentUser.path
        let path = localHome + "/synthetic/project"
        let folder = HerdrHudWorkingFolder(path: path)

        #expect(folder.displayPath(for: local) == "~/synthetic/project")
        #expect(folder.displayPath(for: remote) == path)
        #expect(HerdrHudWorkingFolder(path: "~/synthetic/project").displayPath(for: remote) == "~/synthetic/project")
        #expect(HerdrHudWorkingFolder.home.requestPath == nil)
        #expect(folder.requestPath == path)
    }

    @Test("Switching machines resets a fresh composer to that machine's home")
    func switchingMachinesResetsFreshComposer() throws {
        let defaults = makeDefaults()
        let store = HerdrHudWorkingFolderStore(userDefaults: defaults)
        let session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-hud.json"),
            workingFolderStore: store
        )
        session.selectedMachineID = "studio"
        let custom = try session.addCustomWorkingFolder(path: "/synthetic/studio/project", machineID: "studio")
        #expect(session.selectedWorkingFolder == custom)
        #expect(session.workingFolderOptions(for: "laptop").map(\.path) == ["~"])

        session.selectedMachineID = "laptop"
        #expect(session.selectedWorkingFolder.isHome)
        #expect(session.workingDirectory == nil)
        #expect(session.workingFolderOptions(for: "laptop").map(\.path) == ["~"])
        #expect(session.customWorkingFolders(for: "studio").map(\.path) == ["/synthetic/studio/project"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HerdrHudWorkingFolderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
