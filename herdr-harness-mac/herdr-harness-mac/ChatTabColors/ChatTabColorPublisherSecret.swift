import Foundation
import Security

enum ChatTabColorPublisherSecretError: LocalizedError, Sendable {
    case randomGenerationFailed
    case keychainReadFailed(OSStatus)
    case malformedStoredSecret
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            "Herdr could not generate a tab color publisher secret."
        case .keychainReadFailed:
            "Herdr could not read the tab color publisher secret from Keychain."
        case .malformedStoredSecret:
            "The saved tab color publisher secret is malformed. Remove it from Keychain before sharing again."
        case .keychainWriteFailed:
            "Herdr could not save the tab color publisher secret in Keychain."
        }
    }
}

/// Per-server publication credential.
///
/// The account namespace is deliberately separate from the agent control
/// receiver secret and from any machine name: a companion's UI receiver token
/// can never be replayed as a publisher token, and rotating one does not
/// change the other.
struct ChatTabColorPublisherSecret: Sendable {
    static let accountPrefix = "chat-tab-colors.publisher"

    private let storage: any AgentControlSecretStorage

    init(storage: any AgentControlSecretStorage = KeychainAgentControlSecretStorage()) {
        self.storage = storage
    }

    /// True when the default live Keychain is in use. Tests use this to fail
    /// closed instead of writing a synthetic publisher secret into the user's
    /// real Keychain.
    var usesLiveKeychain: Bool { storage is KeychainAgentControlSecretStorage }

    func token(serverID: String, clientID: String) throws -> String {
        let account = Self.account(serverID: serverID, clientID: clientID)
        let read = storage.read(for: account)
        switch read.status {
        case errSecSuccess:
            guard let value = read.value, Self.isToken(value) else {
                throw ChatTabColorPublisherSecretError.malformedStoredSecret
            }
            return value
        case errSecItemNotFound:
            break
        default:
            throw ChatTabColorPublisherSecretError.keychainReadFailed(read.status)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw ChatTabColorPublisherSecretError.randomGenerationFailed
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let status = storage.set(token, for: account)
        guard status == errSecSuccess else {
            throw ChatTabColorPublisherSecretError.keychainWriteFailed(status)
        }
        return token
    }

    static func account(serverID: String, clientID: String) -> String {
        "\(accountPrefix).\(serverID).\(clientID)"
    }

    static func isToken(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

/// Per-server publication bookkeeping.
///
/// Revisions are persisted before a request is sent so a relaunch, retry, or
/// disable race can never reuse an older revision for newer data. The server
/// rejects lower revisions, which makes the ordering authoritative.
struct ChatTabColorPublicationRecord: Codable, Equatable, Sendable {
    var revision = 0
    var fingerprint: String?
    var enabled = false
    var pendingClear = false
    var lastPublishedAt: Date?
}

struct ChatTabColorPublicationLedger: Codable, Equatable, Sendable {
    var records: [String: ChatTabColorPublicationRecord] = [:]
    /// Last authenticated server identity per configured machine, so disabling
    /// sharing while a companion is offline can still report and later clear
    /// the correct server instead of guessing from a URL or display name.
    var serverIDsByMachine: [String: String] = [:]
}

struct ChatTabColorPublicationLedgerStore {
    static let defaultsKey = "herdr.chatTabColors.publication.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> ChatTabColorPublicationLedger {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let ledger = try? JSONDecoder().decode(ChatTabColorPublicationLedger.self, from: data)
        else { return ChatTabColorPublicationLedger() }
        return ledger
    }

    func save(_ ledger: ChatTabColorPublicationLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
