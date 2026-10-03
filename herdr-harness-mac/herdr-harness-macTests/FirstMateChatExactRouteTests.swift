import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Exact Home feature routes", .serialized)
@MainActor
struct FirstMateChatExactRouteTests {
    @Test("A missing requested machine never falls back to lead or a colliding feature")
    func missingOwner() {
        let fixture = Fixture()
        let target = FirstMateFleetFeatureID(machineID: "missing", featureID: "shared")
        fixture.session.applyExactOpenRequest(fixture.request(target))
        #expect(fixture.session.selection == .feature(target))
        #expect(fixture.session.selectedStore == nil)
        #expect(fixture.session.exactSelectionUnavailableReason != nil)
        #expect(!fixture.session.selectionIsUnresolvable)
        #expect(fixture.alpha.featureCalls == 0 && fixture.beta.featureCalls == 0)
    }

    @Test("A colliding feature ID opens only the requested machine")
    func exactCompositeIdentity() async throws {
        let fixture = Fixture()
        let target = FirstMateFleetFeatureID(machineID: "beta", featureID: "shared")
        fixture.session.applyExactOpenRequest(fixture.request(target))
        let store = try #require(fixture.session.selectedStore)
        await store.refreshConversation()
        #expect(fixture.session.selectedSnapshot?.feature.title == "Beta conversation")
        #expect(fixture.session.selection == .feature(target))
        #expect(fixture.alpha.featureCalls == 0)
        #expect(fixture.beta.featureCalls == 1)
        #expect(fixture.session.exactSelectionUnavailableReason == nil)
    }

    @Test("A queued request rejects a changed connection before creating a store")
    func changedBeforeApply() {
        let fixture = Fixture()
        let target = FirstMateFleetFeatureID(machineID: "alpha", featureID: "shared")
        let request = fixture.request(target)
        fixture.model.connectionGeneration += 1
        fixture.session.applyExactOpenRequest(request)
        #expect(fixture.session.selection == .feature(target))
        #expect(!fixture.session.exactOwnerIsCurrent)
        #expect(fixture.session.selectedStore == nil)
        #expect(fixture.session.exactSelectionUnavailableReason != nil)
        #expect(fixture.alpha.featureCalls == 0)
    }

    @Test("A removed owner remains explicit after a snapshot has loaded")
    func removedAfterHydration() async throws {
        let fixture = Fixture()
        let target = FirstMateFleetFeatureID(machineID: "alpha", featureID: "shared")
        fixture.session.applyExactOpenRequest(fixture.request(target))
        let store = try #require(fixture.session.selectedStore)
        await store.refreshConversation()
        #expect(fixture.session.selectedSnapshot != nil)
        fixture.model.machines.removeAll { $0.id == "alpha" }
        #expect(fixture.session.selection == .feature(target))
        #expect(fixture.session.selectedSnapshot == nil)
        #expect(!fixture.session.selectionIsUnresolvable)
        #expect(fixture.session.exactSelectionUnavailableReason != nil)
    }

    @Test("A missing feature shows unavailable while preserving the requested selection")
    func missingFeature() async throws {
        let fixture = Fixture()
        let target = FirstMateFleetFeatureID(machineID: "alpha", featureID: "missing")
        fixture.session.applyExactOpenRequest(fixture.request(target))
        let store = try #require(fixture.session.selectedStore)
        await store.refreshConversation()
        #expect(fixture.session.selection == .feature(target))
        #expect(fixture.session.exactSelectionUnavailableReason != nil)
        #expect(!fixture.session.selectionIsUnresolvable)
    }

    @Test("New requests for the same target remain distinct and user navigation releases the pin")
    func repeatAndNavigate() {
        let fixture = Fixture()
        let target = FirstMateFleetFeatureID(machineID: "alpha", featureID: "shared")
        let first = fixture.request(target)
        let next = fixture.request(target)
        #expect(first.id != next.id)
        fixture.session.applyExactOpenRequest(first)
        fixture.session.pendingComposerFocus = false
        fixture.session.applyExactOpenRequest(next)
        #expect(fixture.session.exactOpenRequest?.id == next.id)
        #expect(fixture.session.pendingComposerFocus)
        fixture.session.select(.lead)
        #expect(fixture.session.exactOpenRequest == nil)
        #expect(fixture.session.selection == .lead)
    }

    @MainActor
    private final class Fixture {
        let model = ChatFixtures.model(demo: false)
        let shell = ChatFixtures.shell()
        let alpha: SyntheticChatFleetClient
        let beta: SyntheticChatFleetClient
        let session: FirstMateChatWindowSession
        let configurations: [String: ServerConfiguration]

        init() {
            model.machines = [ChatFixtures.machine("alpha"), ChatFixtures.machine("beta")]
            configurations = [
                "alpha": ServerConfiguration(urlString: "https://alpha.example.invalid", token: "synthetic-alpha")!,
                "beta": ServerConfiguration(urlString: "https://beta.example.invalid", token: "synthetic-beta")!
            ]
            alpha = Self.client(title: "Alpha conversation")
            beta = Self.client(title: "Beta conversation")
            let configs = configurations
            let alphaClient = alpha
            let betaClient = beta
            session = FirstMateChatWindowSession(model: model, shell: shell,
                configuration: { configs[$0] },
                makeClient: { $0 == configs["alpha"] ? alphaClient : betaClient })
        }

        func request(_ target: FirstMateFleetFeatureID) -> FirstMateChatExactOpenRequest {
            .init(target: target, identity: .init(configuration: configurations[target.machineID],
                generation: model.connectionGeneration, isDemo: model.isDemoMode))
        }

        static func client(title: String) -> SyntheticChatFleetClient {
            let feature = ChatFixtures.feature("shared", title: title)
            let client = SyntheticChatFleetClient(features: [feature])
            client.snapshots = ["shared": .init(feature: feature)]
            return client
        }
    }
}
