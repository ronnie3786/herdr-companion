import Foundation
import Security

/// Credential persistence is injectable so model tests never require real credentials.
@MainActor
protocol HerdrCredentialStore {
    func value(for account: String) -> String
    @discardableResult func set(_ value: String, for account: String) -> OSStatus
    func removeValue(for account: String)
}

@MainActor
struct KeychainCredentialStore: HerdrCredentialStore {
    func value(for account: String) -> String { KeychainStore.value(for: account) }
    func set(_ value: String, for account: String) -> OSStatus { KeychainStore.set(value, for: account) }
    func removeValue(for account: String) { KeychainStore.removeValue(for: account) }
}
