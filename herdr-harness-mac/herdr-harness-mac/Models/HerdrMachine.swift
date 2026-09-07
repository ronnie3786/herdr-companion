import Foundation

struct HerdrMachine: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var urlString: String
    /// Optional explicit role from the private cluster configuration.
    var role: String? = nil
}

// The generated resource contains only machine metadata. Tokens are entered at runtime.
extension HerdrMachine {
    static func configuredMachines(bundle: Bundle = .main) -> [HerdrMachine] {
        guard let url = bundle.url(forResource: "HerdrBootstrap", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let machines = try? PropertyListDecoder().decode([HerdrMachine].self, from: data) else { return [] }
        return machines.filter { machine in
            guard let components = URLComponents(string: machine.urlString),
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  let host = components.host?.lowercased() else { return false }
            let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
            return components.scheme == "https" || (components.scheme == "http" && loopback)
        }
    }
}
