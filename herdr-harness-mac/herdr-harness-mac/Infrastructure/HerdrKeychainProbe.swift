import Foundation
import Security

/// A probe can address only a synthetic item, never an application credential.
@MainActor
enum HerdrKeychainProbe {
    static let argument = "--herdr-keychain-probe"

    enum Operation: String, Encodable { case write, read, delete }

    struct Report: Encodable {
        let operation: Operation?
        let status: OSStatus
        let verificationStatus: OSStatus?
        let verified: Bool
        let ok: Bool
    }

    static func runIfRequested(
        arguments: [String],
        store: any HerdrKeychainProbeStore = SecurityKeychainProbeStore()
    ) -> Report? {
        guard arguments.contains(argument) else { return nil }
        guard arguments.count == 4, arguments[1] == argument,
              let operation = Operation(rawValue: arguments[2]),
              let id = UUID(uuidString: arguments[3]) else {
            return Report(operation: nil, status: errSecParam, verificationStatus: nil, verified: false, ok: false)
        }
        let account = "herdr.synthetic-keychain-probe." + id.uuidString.lowercased()
        let expected = Data(("Herdr synthetic Keychain probe " + id.uuidString).utf8)
        switch operation {
        case .write:
            let status = store.create(expected, account: account)
            guard status == errSecSuccess else {
                return Report(operation: operation, status: status, verificationStatus: nil, verified: false, ok: false)
            }
            let read = store.read(account: account)
            let verified = read.status == errSecSuccess && read.data == expected
            return Report(operation: operation, status: status, verificationStatus: read.status, verified: verified, ok: verified)
        case .read:
            let read = store.read(account: account)
            let verified = read.status == errSecSuccess && read.data == expected
            return Report(operation: operation, status: read.status, verificationStatus: nil, verified: verified, ok: verified)
        case .delete:
            let status = store.delete(account: account)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                return Report(operation: operation, status: status, verificationStatus: nil, verified: false, ok: false)
            }
            let read = store.read(account: account)
            let verified = read.status == errSecItemNotFound && read.data == nil
            return Report(operation: operation, status: status, verificationStatus: read.status, verified: verified, ok: verified)
        }
    }
}

@MainActor
protocol HerdrKeychainProbeStore {
    func create(_ data: Data, account: String) -> OSStatus
    func read(account: String) -> (status: OSStatus, data: Data?)
    func delete(account: String) -> OSStatus
}

/// Uses the signed app's production Keychain namespace with interaction disabled.
/// No legacy migration or UserDefaults reads/writes occur in a diagnostic launch.
@MainActor
struct SecurityKeychainProbeStore: HerdrKeychainProbeStore {
    func create(_ data: Data, account: String) -> OSStatus {
        let interaction = SecKeychainSetUserInteractionAllowed(false)
        guard interaction == errSecSuccess else { return interaction }
        let insert = MacKeychainQueries.insertion(query(account), data: data, backend: HerdrAppIdentity.keychainBackend)
        guard insert.status == errSecSuccess else { return insert.status }
        return SecItemAdd(insert.attributes as CFDictionary, nil)
    }

    func read(account: String) -> (status: OSStatus, data: Data?) {
        let interaction = SecKeychainSetUserInteractionAllowed(false)
        guard interaction == errSecSuccess else { return (interaction, nil) }
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(account: String) -> OSStatus {
        let interaction = SecKeychainSetUserInteractionAllowed(false)
        guard interaction == errSecSuccess else { return interaction }
        return SecItemDelete(query(account) as CFDictionary)
    }

    private func query(_ account: String) -> [String: Any] {
        var attributes = KeychainStore.secureItemQuery(for: account)
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return attributes
    }
}
