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

    @Test("Length defaults to minimal, survives relaunch, and rejects invalid stored values")
    func lengthDefaultsAndPersistence() throws {
        let suite = "response-brief-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ResponseBriefPreferences(defaults: defaults)

        #expect(preferences.length == .minimal)
        #expect(ResponseBriefLength.fallback == .minimal)

        preferences.replaceLength(.long)
        #expect(ResponseBriefPreferences(defaults: defaults).length == .long)

        defaults.set("compact", forKey: "herdr.responseBrief.length.v1")
        #expect(ResponseBriefPreferences(defaults: defaults).length == .minimal)
    }

    @Test("Length changes are observable and independent of opt-in, model, and thinking")
    func lengthIsObservableAndIndependent() throws {
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
        preferences.replaceModel("synthetic/provider-model")
        preferences.replaceThinkingLevel("high")

        let didObserveMutation = Mutex(false)
        withObservationTracking {
            _ = preferences.length
        } onChange: {
            didObserveMutation.withLock { $0 = true }
        }

        preferences.replaceLength(.medium)

        #expect(didObserveMutation.withLock { $0 })
        #expect(preferences.length == .medium)
        #expect(preferences.isEnabled(chat))
        #expect(preferences.model == "synthetic/provider-model")
        #expect(preferences.thinkingLevel == "high")
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
