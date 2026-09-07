import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Signed update configuration")
struct HerdrUpdateConfigurationTests {
    private var valid: [String: Any] {
        ["HerdrUpdateBundleIdentifier": "org.example.app",
         "SUFeedURL": "https://example.com/releases/appcast.xml",
         "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
         "SURequireSignedFeed": true,
         "SUVerifyUpdateBeforeExtraction": true]
    }

    @Test("A public build pins an HTTPS feed and Ed25519 key")
    func validConfiguration() {
        #expect(HerdrUpdateConfiguration(info: valid, bundleIdentifier: "org.example.app")?.feedURL.absoluteString == "https://example.com/releases/appcast.xml")
    }

    @Test("Private and downstream identities cannot use an incompatible feed")
    func differentIdentity() {
        #expect(HerdrUpdateConfiguration(info: valid, bundleIdentifier: "org.example.private") == nil)
        #expect(HerdrUpdateConfiguration(info: valid, bundleIdentifier: nil) == nil)
    }

    @Test("Unsigned feeds and unverified extraction cannot be enabled")
    func requiredTrust() {
        for field in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var info = valid
            info[field] = false
            #expect(HerdrUpdateConfiguration(info: info, bundleIdentifier: "org.example.app") == nil)
        }
        for key in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = valid
            info["SUPublicEDKey"] = key
            #expect(HerdrUpdateConfiguration(info: info, bundleIdentifier: "org.example.app") == nil)
        }
    }

    @Test("Feed URLs cannot contain credentials or use insecure transport")
    func unsafeFeeds() {
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/feed", "https://example.com/feed?token=example", "https://example.com/feed#fragment", "https://"] {
            var info = valid
            info["SUFeedURL"] = feed
            #expect(HerdrUpdateConfiguration(info: info, bundleIdentifier: "org.example.app") == nil)
        }
    }
}
