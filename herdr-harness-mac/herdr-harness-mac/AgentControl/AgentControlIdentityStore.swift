import Foundation
import Security

struct AgentControlSecretRead: Sendable {
    let status: OSStatus
    let value: String?
}

protocol AgentControlSecretStorage: Sendable {
    func read(for account: String) -> AgentControlSecretRead
    @discardableResult func set(_ value: String, for account: String) -> OSStatus
}

struct KeychainAgentControlSecretStorage: AgentControlSecretStorage {
    func read(for account: String) -> AgentControlSecretRead {
        var query = KeychainStore.secureItemQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return AgentControlSecretRead(status: status, value: nil) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return AgentControlSecretRead(status: errSecDecode, value: nil)
        }
        return AgentControlSecretRead(status: errSecSuccess, value: value)
    }

    func set(_ value: String, for account: String) -> OSStatus {
        KeychainStore.set(value, for: account)
    }
}

struct AgentControlIdentityStore {
    enum IdentityError: LocalizedError {
        case randomGenerationFailed
        case keychainReadFailed(OSStatus)
        case malformedStoredSecret
        case keychainWriteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .randomGenerationFailed:
                "Herdr could not generate an agent control secret."
            case .keychainReadFailed:
                "Herdr could not read the agent control secret from Keychain."
            case .malformedStoredSecret:
                "The saved agent control secret is malformed. Remove it from Keychain before pairing again."
            case .keychainWriteFailed:
                "Herdr could not save the agent control secret in Keychain."
            }
        }
    }

    private static let clientIDKey = "herdr.agentControl.clientID.v1"
    private let defaults: UserDefaults
    private let storage: any AgentControlSecretStorage

    init(defaults: UserDefaults = .standard, storage: any AgentControlSecretStorage = KeychainAgentControlSecretStorage()) {
        self.defaults = defaults
        self.storage = storage
    }

    func clientID() -> String {
        if let saved = defaults.string(forKey: Self.clientIDKey),
           saved.hasPrefix("ui_"), UUID(uuidString: String(saved.dropFirst(3))) != nil {
            return saved
        }
        let value = "ui_\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: Self.clientIDKey)
        return value
    }

    func receiverToken(serverID: String, clientID: String) throws -> String {
        let account = "agent-control.receiver.\(serverID).\(clientID)"
        let read = storage.read(for: account)
        switch read.status {
        case errSecSuccess:
            guard let value = read.value, Self.isReceiverToken(value) else {
                throw IdentityError.malformedStoredSecret
            }
            return value
        case errSecItemNotFound:
            break
        default:
            throw IdentityError.keychainReadFailed(read.status)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw IdentityError.randomGenerationFailed }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let status = storage.set(token, for: account)
        guard status == errSecSuccess else { throw IdentityError.keychainWriteFailed(status) }
        return token
    }

    static func isReceiverToken(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
