import Foundation
import Security
@testable import herdr_harness_mac

@MainActor
final class TestCredentialStore: HerdrCredentialStore {
    var values: [String: String] = [:]
    var saveStatus: OSStatus = errSecSuccess

    func value(for account: String) -> String { values[account] ?? "" }
    @discardableResult
    func set(_ value: String, for account: String) -> OSStatus {
        guard saveStatus == errSecSuccess else { return saveStatus }
        if value.isEmpty { values.removeValue(forKey: account) }
        else { values[account] = value }
        return errSecSuccess
    }
    func removeValue(for account: String) { values.removeValue(forKey: account) }
}
