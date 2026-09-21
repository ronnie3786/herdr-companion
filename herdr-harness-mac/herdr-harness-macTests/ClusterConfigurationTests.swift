import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Portable machine configuration")
struct ClusterConfigurationTests {
    @Test("Older saved machine records remain decodable without a role")
    func legacyMachineHasNoInferredRole() throws {
        let data = Data(#"{"id":"old","name":"Work Mac","urlString":"https://desktop.example.test"}"#.utf8)
        let machine = try JSONDecoder().decode(HerdrMachine.self, from: data)
        #expect(machine.role == nil)
        let store = FleetStore(machines: [machine], connectionStates: [:])
        #expect(store.machines.first?.role == .node)
    }

    @Test("Older bootstrap plists decode without sidebar presentation fields")
    func legacyBootstrapPlist() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [[
                "id": "old-plist",
                "name": "Legacy Computer",
                "urlString": "https://legacy.example.test",
                "role": "node",
            ]],
            format: .xml,
            options: 0
        )
        let machines = try PropertyListDecoder().decode([HerdrMachine].self, from: data)

        #expect(machines[0].sidebarLabel == nil)
        #expect(machines[0].sidebarOrder == nil)
    }

    @Test("Machine names and URL labels never select a private machine role")
    func arbitraryNamesRemainNodes() {
        let source = [
            HerdrMachine(id: "one", name: "Work Mac", urlString: "http://localhost:9092"),
            HerdrMachine(id: "two", name: "Development Studio", urlString: "https://desktop.example.test"),
        ]
        let store = FleetStore(machines: source, connectionStates: [:])
        #expect(store.machines.map(\.role) == [.node, .node])
    }
}
