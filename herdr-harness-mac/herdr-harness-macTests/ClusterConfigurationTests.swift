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
