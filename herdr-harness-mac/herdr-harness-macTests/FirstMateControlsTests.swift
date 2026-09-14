import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate live controls")
@MainActor
struct FirstMateControlsTests {
    @Test func navigationIsScopedAndReadOnly() throws {
        let url = try #require(URL(string: "herdr://first-mate?feature_id=fmf_example&server_url=https%3A%2F%2Fcompanion.example.test&tab=workflow&view=graph"))
        let request = try #require(FirstMateOpenRequest(url: url))
        #expect(request.featureID == "fmf_example")
        #expect(request.tab == .workflow)
        #expect(request.graph)
        for text in [
            "herdr://first-mate?feature_id=x&server_url=http%3A%2F%2Fremote.example.test",
            "herdr://first-mate?feature_id=x&feature_id=y&server_url=https%3A%2F%2Fexample.test",
            "herdr://first-mate?feature_id=x&server_url=https%3A%2F%2Fexample.test&prompt=execute",
            "herdr://first-mate?feature_id=x&server_url=https%3A%2F%2Fexample.test&tab=invalid"
        ] { #expect(FirstMateOpenRequest(url: try #require(URL(string: text))) == nil) }
    }

    @Test func exitingDemoRestoresSavedMachinesAndCredentials() throws {
        let name = "FirstMateControlsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = TestCredentialStore()
        let model = HerdrAppModel(credentials: credentials, arguments: ["test"], userDefaults: defaults)
        #expect(model.addMachine(name: "Synthetic host", urlString: "https://companion.example.test", token: "synthetic-token"))
        let machine = try #require(model.machines.first)
        model.useDemo()
        #expect(model.isDemoMode)
        model.leaveDemo()
        #expect(!model.isDemoMode)
        #expect(model.hasCompletedSetup)
        #expect(!defaults.bool(forKey: "herdr.demoMode"))
        #expect(defaults.bool(forKey: "herdr.completedSetup"))
        #expect(model.firstMateConfiguration(machineID: machine.id)?.token == "synthetic-token")
    }
    @Test func hostSelectionDoesNotReorderSavedMachines() throws {
        let name = "FirstMateControlsTests.hosts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let credentials = TestCredentialStore()
        let model = HerdrAppModel(credentials: credentials, arguments: ["test"], userDefaults: defaults)
        #expect(model.addMachine(name: "One", urlString: "https://one.example.test", token: "one-token"))
        #expect(model.addMachine(name: "Two", urlString: "https://two.example.test", token: "two-token"))
        let before = model.machines
        let second = try #require(before.last)
        #expect(model.firstMateConfiguration(machineID: second.id)?.token == "two-token")
        #expect(model.machines == before)
    }

}
