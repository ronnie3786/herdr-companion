import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Mobile First Mate safe links")
@MainActor
struct FirstMateMobileDeepLinkTests {
    private let machines = [
        HerdrMachine(id: "alpha", name: "Same name", urlString: "https://alpha.example.invalid:443/"),
        HerdrMachine(id: "beta", name: "Same name", urlString: "https://beta.example.invalid"),
    ]
    private func parse(_ value: String) throws -> FirstMateMobileOpenRequest {
        let url = try #require(URL(string: value))
        return try #require(FirstMateMobileOpenRequest(url: url))
    }

    @Test("Feature, assignment and lead forms are additive without relaxing the Mac parser")
    func grammar() throws {
        let feature = try parse("herdr://first-mate?feature_id=fmf_a")
        #expect(feature.destination == .feature("fmf_a") && feature.origin == nil)
        #expect(FirstMateOpenRequest(url: URL(string: "herdr://first-mate?feature_id=fmf_a")!) == nil)
        let agent = try parse("herdr://first-mate?feature_id=fmf_a&assignment_id=assignment_1&tab=agents")
        #expect(agent.assignmentID == "assignment_1" && agent.inspector == .agents)
        #expect(try parse("herdr://first-mate/lead").destination == .lead)
        #expect(try parse("herdr://first-mate?feature_id=f&server_url=https%3A%2F%2FALPHA.example.invalid%3A443%2F").origin == "https://alpha.example.invalid")
    }

    @Test("Security-bearing, duplicate and invalid fields cannot select a destination", arguments: [
        "herdr://first-mate?feature_id=f&feature_id=g", "herdr://first-mate?feature_id=f&feature%5Fid=g",
        "herdr://first-mate?feature_id=..", "herdr://first-mate?feature_id=a%2Fb", "herdr://first-mate?feature_id=a%3Fq",
        "herdr://first-mate?feature_id=f&assignment_id=../a", "herdr://first-mate?assignment_id=a",
        "herdr://first-mate?feature_id=f&token=secret", "herdr://first-mate?feature_id=f&prompt=send",
        "herdr://first-mate?feature_id=f&server_url=https%3A%2F%2Fuser%3Apass%40alpha.example.invalid",
        "herdr://first-mate?feature_id=f&server_url=https%3A%2F%2Falpha.example.invalid%2Fpath",
        "herdr://first-mate?feature_id=f&server_url=https%3A%2F%2Falpha.example.invalid&server_url=https%3A%2F%2Fbeta.example.invalid",
        "herdr://user@first-mate?feature_id=f", "herdr://first-mate:99?feature_id=f",
        "herdr://first-mate/lead?feature_id=f", "herdr://first-mate/lead?assignment_id=a",
        "herdr://first-mate?feature_id=f#fragment", "herdr://first-mate?feature_id=f&tab=unknown",
    ])
    func invalid(_ raw: String) {
        #expect(URL(string: raw).flatMap(FirstMateMobileOpenRequest.init(url:)) == nil)
    }

    @Test("External ownership is unique or exact-origin; labels and roster order never choose")
    func ownership() throws {
        let hosts = machines.map { ChatFixtures.host($0.id, features: [ChatFixtures.feature("same-id")]) }
        let unqualified = try parse("herdr://first-mate?feature_id=same-id")
        guard case .failure = unqualified.resolve(machines: machines, hosts: hosts, owner: nil) else { Issue.record("Ambiguous owner"); return }
        guard case .failure = unqualified.resolve(machines: machines.reversed(), hosts: hosts.reversed(), owner: nil) else { Issue.record("Roster order is not identity"); return }
        let owner = FirstMateFeatureTarget(machineID: "beta", featureID: "current")
        #expect(unqualified.resolve(machines: machines, hosts: hosts, owner: owner) == .feature(.init(machineID: "beta", featureID: "same-id")))
        #expect(unqualified.resolve(machines: machines, hosts: [hosts[0]], owner: nil) == .feature(.init(machineID: "alpha", featureID: "same-id")))
        let explicit = try parse("herdr://first-mate?feature_id=same-id&server_url=https%3A%2F%2Falpha.example.invalid")
        #expect(explicit.resolve(machines: machines, hosts: hosts, owner: owner) == .feature(.init(machineID: "alpha", featureID: "same-id")))
        let duplicateOrigin = machines + [.init(id: "other", name: "Other", urlString: "https://alpha.example.invalid")]
        guard case .failure = explicit.resolve(machines: duplicateOrigin, hosts: hosts, owner: owner) else { Issue.record("Ambiguous origin"); return }
        let unknown = try parse("herdr://first-mate?feature_id=same-id&server_url=https%3A%2F%2Funknown.example.invalid")
        guard case .failure = unknown.resolve(machines: machines, hosts: hosts, owner: owner) else { Issue.record("Unknown explicit origin must not fall back"); return }
        #expect(try parse("herdr://first-mate/lead").resolve(machines: machines, hosts: hosts, owner: nil) == .lead(nil))
    }

    @Test("Assignment routing validates the exact feature and retains the info target")
    func assignmentRoute() async throws {
        let defaults = UserDefaults(suiteName: "MobileRoute.\(UUID())")!
        let fleet = FirstMateMobileFleetStore(defaults: defaults)
        fleet.activate(sources: [.init(machine: machines[0], configuration: nil, client: nil, isDemo: true)], connectionGeneration: 1)
        await fleet.refresh()
        let store = try #require(fleet.store(forMachineID: "alpha"))
        let snapshot = try #require(store.snapshots.values.first { !$0.assignments.isEmpty })
        let assignment = try #require(snapshot.assignments.first)
        let raw = "herdr://first-mate?feature_id=\(snapshot.feature.id)&assignment_id=\(assignment.id)&server_url=https%3A%2F%2Falpha.example.invalid"
        let request = try parse(raw)
        #expect(await fleet.chat.navigate(request, fleet: fleet))
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: snapshot.feature.id)
        #expect(fleet.chat.route?.target == target)
        #expect(fleet.chat.route?.assignmentID == assignment.id)
        #expect(fleet.chat.path == [.chat(target), .info(target, assignmentID: assignment.id)])
        let invalid = try parse("herdr://first-mate?feature_id=\(snapshot.feature.id)&assignment_id=not-owned&server_url=https%3A%2F%2Falpha.example.invalid")
        #expect(!(await fleet.chat.navigate(invalid, fleet: fleet)))
        #expect(fleet.selectedTarget == target)
        fleet.selectTarget(nil)
        #expect(fleet.chat.route == nil && fleet.chat.path.isEmpty)
    }

    @Test("Exact-origin links load an unlisted lead or archive before selecting its owner")
    func unlistedFeatureRoute() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "UnlistedRoute.\(UUID())")!)
        let client = SyntheticChatFleetClient()
        let lead = FirstMateDemo.chatWindowLead()
        var archived = FirstMateDemo.features(step: 0)[0]
        archived.feature.archivedAt = "2030-01-01T00:00:00Z"
        client.snapshots = [lead.feature.id: lead, archived.feature.id: archived]
        let machine = machines[0]
        fleet.activate(sources: [.init(machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "synthetic"), client: client)], connectionGeneration: 1)
        for snapshot in [lead, archived] {
            let request = try parse("herdr://first-mate?feature_id=\(snapshot.feature.id)&server_url=https%3A%2F%2Falpha.example.invalid")
            #expect(await fleet.chat.navigate(request, fleet: fleet))
            #expect(fleet.selectedTarget == .init(machineID: "alpha", featureID: snapshot.feature.id))
            #expect(fleet.selectedStore?.snapshot?.feature.id == snapshot.feature.id)
        }
        #expect(fleet.showArchived)
        #expect(client.featureCalls == 2 && client.ensureCalls == 0 && client.sent.isEmpty)
    }

    @Test("Existing pane and car link parsing remains separate")
    func otherRoutes() {
        #expect(HerdrAppModel.paneID(from: URL(string: "herdr://pane/synthetic-pane")!) == "synthetic-pane")
        #expect(HerdrAppModel.paneID(from: URL(string: "https://phone.example.invalid/open/pane/synthetic-pane")!) == "synthetic-pane")
        #expect(FirstMateMobileOpenRequest(url: URL(string: "herdr://car")!) == nil)
    }
}
