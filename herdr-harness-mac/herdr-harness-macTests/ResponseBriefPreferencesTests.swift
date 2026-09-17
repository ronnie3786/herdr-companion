import Foundation
import Observation
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Response brief preferences", .serialized)
@MainActor
struct ResponseBriefPreferencesTests {
    @Test("Opt-in mutations are observable and store metadata only")
    func optInIsObservableMetadata() throws {
        let suite = "response-brief-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ResponseBriefPreferences(defaults: defaults)
        let chat = ResponseBriefChatIdentity(
            machineID: "synthetic-machine",
            paneID: "w1:p1",
            sessionID: "synthetic-session"
        )
        let didObserveMutation = Mutex(false)
        withObservationTracking {
            _ = preferences.enabledChats
        } onChange: {
            didObserveMutation.withLock { $0 = true }
        }

        #expect(preferences.enable(chat))
        #expect(didObserveMutation.withLock { $0 })
        #expect(preferences.isEnabled(chat))

        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(!String(describing: persisted).contains("private response text"))
    }

    @Test("Disable immediately changes observable opt-in state")
    func disableIsImmediate() throws {
        let suite = "response-brief-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ResponseBriefPreferences(defaults: defaults)
        let chat = ResponseBriefChatIdentity(
            machineID: "synthetic-machine",
            paneID: "w1:p1",
            sessionID: "synthetic-session"
        )
        #expect(preferences.enable(chat))

        preferences.disable(chat)

        #expect(!preferences.isEnabled(chat))
    }
}

@Suite("Response brief app isolation", .serialized)
@MainActor
struct ResponseBriefAppIsolationTests {
    @Test("Demo and tests expose no response brief network transport")
    func networkIsDisabled() async throws {
        let suite = "response-brief-isolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let transport = model.responseBriefTransport()

        #expect(!model.responseBriefNetworkingEnabled)
        await #expect(throws: ResponseBriefCoordinatorError.self) {
            _ = try await transport.capabilities("synthetic-machine")
        }
    }
}
