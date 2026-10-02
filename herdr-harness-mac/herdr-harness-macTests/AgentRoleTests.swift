import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Role contract")
struct AgentRoleTests {
    @Test("Legacy roles decode with worker defaults and retain the legacy wire shape")
    func legacyRole() throws {
        let json = """
            {"id":"worker","builtin":true,"locked":false,"name":"Worker","whenToUse":"",
             "systemPrompt":"","modelProfile":"execution","allowDelegation":false,"skillIds":null}
            """
        let role = try JSONDecoder().decode(AgentRole.self, from: Data(json.utf8))
        #expect(role.purpose == "worker")
        #expect(role.reviewPrompt.isEmpty)
        #expect(role.group.isEmpty)
        #expect(role.avatar == "review")
        #expect(!role.isPRReview)
        #expect(role.skillIds == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(role)) as? [String: Any])
        #expect(object["purpose"] == nil)
        #expect(object["reviewPrompt"] == nil)
        #expect(object["group"] == nil)
        #expect(object["avatar"] == nil)
        #expect(object["skillIds"] is NSNull)
        #expect(try JSONDecoder().decode(AgentRole.self, from: JSONEncoder().encode(role)) == role)
    }

    @Test("Review fields round trip and participate in save confirmation equality")
    func reviewRoundTrip() throws {
        let role = AgentRoleTestFixtures.reviewRoles[1]
        let encoded = try JSONEncoder().encode(role)
        let decoded = try JSONDecoder().decode(AgentRole.self, from: encoded)
        #expect(decoded == role)
        #expect(decoded.isPRReview)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["purpose"] as? String == "pr_review")
        #expect(object["reviewPrompt"] as? String == role.reviewPrompt)
        #expect(object["group"] as? String == "Sample team")
        #expect(object["avatar"] as? String == "quality")
        var changed = role
        changed.avatar = "security"
        #expect(changed != role)
        changed = role
        changed.group = "Another sample team"
        #expect(changed != role)
        changed = role
        changed.reviewPrompt = "Changed review instructions"
        #expect(changed != role)
    }

    @Test("New review profiles use host defaults with strict empty skills and a blank prompt")
    func newReviewDefaults() throws {
        let role = AgentRole.customPRReview()
        #expect(UUID(uuidString: role.id) != nil)
        #expect(!role.builtin && !role.locked && role.isPRReview)
        #expect(role.modelProfile == "default")
        #expect(!role.allowDelegation)
        #expect(role.whenToUse.isEmpty && role.systemPrompt.isEmpty)
        #expect(role.skillIds == [])
        #expect(role.reviewPrompt.isEmpty && role.group.isEmpty)
        #expect(role.avatar == "review")
        #expect(try JSONDecoder().decode(AgentRole.self, from: JSONEncoder().encode(role)) == role)
        #expect(AgentRole.defaultReviewPrompt.hasSuffix("Pull request: {url}"))
    }

    @Test("Overview capability negotiation remains optional for older companions")
    func legacyOverview() throws {
        let overview = AgentRoleTestFixtures.overview()
        let decoded = try JSONDecoder().decode(AgentRolesOverview.self, from: JSONEncoder().encode(overview))
        #expect(decoded.capabilities == nil)
        #expect(!decoded.supportsPRReviewAgents)
        let supported = AgentRoleTestFixtures.reviewOverview()
        #expect(try JSONDecoder().decode(AgentRolesOverview.self, from: JSONEncoder().encode(supported)).supportsPRReviewAgents)
    }
}
