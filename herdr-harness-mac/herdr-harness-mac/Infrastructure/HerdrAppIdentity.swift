import Foundation

/// Build identity comes from the optional private Apple configuration.
enum HerdrAppIdentity {
    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "org.herdr.companion" }
    static var keychainService: String { setting("HerdrKeychainService") ?? bundleIdentifier }
    static var keychainBackend: MacKeychainBackend {
        setting("HerdrMacKeychainBackend").flatMap(MacKeychainBackend.init(rawValue:)) ?? .login
    }
    static var legacyKeychainService: String? { setting("HerdrLegacyKeychainService") }
    static var terminalBundleIdentifier: String? { setting("HerdrTerminalBundleIdentifier") }
    static var pushEnvironment: String {
        if let configured = setting("HerdrAPNsEnvironment") {
            return configured == "development" ? "sandbox" : "production"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private static func setting(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }
}
