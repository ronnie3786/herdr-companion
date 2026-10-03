import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Home projection", .serialized)
@MainActor
struct HomeProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_791_028_800)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.locale = Locale(identifier: "en_US")
        return value
    }
    private var machines: [HomeMachineFact] {
        [.init(id: "one", name: "North", state: .online), .init(id: "two", name: "South", state: .online)]
    }
    private var current: [HomeSourceFact] { [.init(id: "fixture", state: .current)] }

    @Test("Identical server IDs retain exact owners and stable tied priority order")
    func scopedIdentityAndOrder() {
        let features = [feature(machine: "two", id: "same", state: .needsDecision), feature(machine: "one", id: "same", state: .blocked)]
        let reviews = [review(machine: "two", id: "same", state: .failed), review(machine: "one", id: "same", state: .ready, needsUser: true)]
        let first = project(HomeInput(machines: machines, sources: current, features: features, reviews: reviews))
        let second = project(HomeInput(machines: Array(machines.reversed()), sources: current,
                                       features: Array(features.reversed()), reviews: Array(reviews.reversed())))
        #expect(first.focus.map(\.id) == second.focus.map(\.id))
        #expect(Set(first.focus.map(\.id)).count == 4)
        #expect(first.focus.map(\.route) == [.firstMate(machineID: "one", featureID: "same"),
                                           .firstMate(machineID: "two", featureID: "same"),
                                           .review(machineID: "two", reviewID: "same"),
                                           .review(machineID: "one", reviewID: "same")])
        #expect(first.focusCount == 4)
        #expect(HomeIdentity.scoped(kind: "a", machineID: "b:c", entityID: "d") != HomeIdentity.scoped(kind: "a", machineID: "b", entityID: "c:d"))
    }

    @Test("Lead, closed, archived and removed-host features never inflate attention")
    func retainedFeatureScope() {
        let features = [feature(id: "decision", state: .needsDecision), feature(id: "closed", state: .closed),
                        feature(id: "archived", state: .blocked, archived: true), feature(id: "lead", state: .blocked, lead: true),
                        feature(machine: "removed", id: "gone", state: .blocked)]
        let value = project(HomeInput(machines: machines, sources: current, features: features))
        #expect(value.focusCount == 1)
        #expect(value.focus.first?.route == .firstMate(machineID: "one", featureID: "decision"))
    }

    @Test("Only validated same-host repository identities deduplicate incoming requests")
    func canonicalRequests() throws {
        let identity = try #require(HomePullRequestIdentity(url: "https://GITHUB.com/Example/Tools/pull/17?view=files#top", repository: "example/tools", number: 17))
        #expect(identity.url == "https://github.com/example/tools/pull/17")
        let enterprise = try #require(HomePullRequestIdentity(url: "https://code.example.test/example/tools/pull/17", repository: "example/tools", number: 17))
        let otherRepo = try #require(HomePullRequestIdentity(url: "https://github.com/example/other/pull/17", repository: "example/other", number: 17))
        let reviews = [review(id: "r1", state: .ready, needsUser: true, pr: identity),
                       review(machine: "two", id: "r1", state: .ready, needsUser: true, pr: identity)]
        let requests = [identity, identity, enterprise, otherRepo].map { HomeReviewRequestFact(pullRequest: $0, title: $0.label) }
        let value = project(HomeInput(machines: machines, sources: current, reviews: reviews, reviewRequests: requests))
        #expect(value.reviewCount == 4)
        #expect(value.focus.count == 4)
        #expect(value.focus.filter { if case .reviewRequest = $0.route { true } else { false } }.count == 2)
        #expect(value.focus.contains { $0.route == .review(machineID: "two", reviewID: "r1") })
    }

    @Test("Unsafe, malformed, or metadata-mismatched PR URLs never become routes")
    func invalidCanonicalIdentities() {
        let invalid = ["http://github.com/example/tools/pull/17", "https://name:secret@github.com/example/tools/pull/17",
                       "https://github.com:8443/example/tools/pull/17", "https://github.com/example/tools/pull/17/files",
                       "https://github.com/example/tools/pull/18", "https://github.com/example/other/pull/17",
                       "https://github.com/example%2Ftools/pull/17", "https://github.com/example/tools/pull/-17",
                       "https://github.com//example/tools/pull/17", "https://github.com/example/tools/pull/17\nnext"]
        for url in invalid { #expect(HomePullRequestIdentity(url: url, repository: "example/tools", number: 17) == nil) }
    }

    @Test("Unknown reviews remain unknown and preparation failure stays distinct from a ready request")
    func unknownReviewState() throws {
        let identity = try #require(HomePullRequestIdentity(url: "https://github.com/example/tools/pull/17", repository: "example/tools", number: 17))
        let reviews = [review(id: "unknown", state: .unknown, needsUser: true, pr: identity),
                       review(id: "failed", state: .failed), review(id: "ready-no-request", state: .ready)]
        let value = project(HomeInput(machines: machines, sources: current, reviews: reviews,
                                      reviewRequests: [.init(pullRequest: identity, title: "Already prepared")]))
        #expect(value.reviewCount == 0)
        #expect(value.reviewNeedsAttention)
        #expect(value.focus.map(\.route) == [.review(machineID: "one", reviewID: "failed")])
        #expect(!value.canShowAllClear)
        #expect(value.notices.contains { $0.contains("unknown status") })
    }

    @Test("No machines, initial loading, disconnected, stale and verified clear are different")
    func availabilityIsEvidenceBased() {
        #expect(project(HomeInput()).availability == .noMachines)
        #expect(project(HomeInput(machines: machines)).availability == .loading)
        let offline = [HomeMachineFact(id: "one", name: "North", state: .offline)]
        let disconnected = project(HomeInput(machines: offline, sources: [.init(id: "source", state: .unavailable)]))
        #expect(disconnected.availability == .disconnected)
        #expect(!disconnected.canShowAllClear)
        let stale = project(HomeInput(machines: machines, sources: [.init(id: "source", state: .stale, notice: "GitHub is unavailable")]))
        #expect(stale.availability == .stale)
        #expect(!stale.canShowAllClear)
        #expect(stale.notices.contains("GitHub is unavailable"))
        let loading = project(HomeInput(machines: machines, sources: [.init(id: "source", state: .loading)]))
        #expect(loading.isLoading && !loading.canShowAllClear)
        let clear = project(HomeInput(machines: machines, sources: current, leadAvailable: true))
        #expect(clear.availability == .current && clear.canShowAllClear)
        #expect(clear.statusLine == "All clear for now")
        #expect(clear.focus.allSatisfy { $0.isIdea })
        #expect(clear.focusCount == 0)
    }

    @Test("Ready reviews with missing viewer attention and expired sources never imply all clear")
    func missingAttentionAndExpiredSource() {
        let unknown = HomeReviewFact(machineID: "one", machineName: "North", reviewID: "review", title: "Ready",
                                     state: .ready, userAttentionKnown: false)
        let attention = project(HomeInput(machines: machines, sources: current, reviews: [unknown]))
        #expect(attention.focusCount == 0 && attention.reviewCount == 0)
        #expect(!attention.canShowAllClear)
        let expired = project(HomeInput(machines: machines, sources: [.init(id: "source", state: .current,
                                                                           updatedAt: now.addingTimeInterval(-601))]))
        #expect(expired.availability == .stale)
        #expect(!expired.canShowAllClear)
    }

    @Test("A second outage changes its evidence fingerprint even when its error is identical")
    func outageEpisodes() {
        func input(_ date: Date) -> HomeInput {
            HomeInput(machines: [.init(id: "one", name: "North", state: .offline, needsAttention: true,
                                        failureBeganAt: date)], sources: [.init(id: "source", state: .unavailable)])
        }
        let first = project(input(now.addingTimeInterval(-600)))
        let second = project(input(now.addingTimeInterval(-60)))
        #expect(first.focus.first?.id == second.focus.first?.id)
        #expect(first.focus.first?.fingerprint != second.focus.first?.fingerprint)
        #expect(first.focus.first?.priority == 0)
    }

    @Test("A failed source retains its attention evidence while another host remains usable")
    func staleAttentionSurvives() {
        let sources: [HomeSourceFact] = [.init(id: "one", state: .stale, notice: "North unavailable"), .init(id: "two", state: .current)]
        let value = project(HomeInput(machines: machines, sources: sources,
                                      features: [feature(state: .blocked, stale: true), feature(machine: "two", id: "live", state: .needsDecision)]))
        #expect(value.availability == .stale)
        #expect(value.focusCount == 2)
        #expect(value.focus.first?.isStale == true)
        #expect(value.focus.last?.isStale == false)
        #expect(!value.canShowAllClear)
    }

    @Test("Waiting chats count input requests, while unread completions remain a different kind of card")
    func chatEvidence() {
        let chats: [HomeChatFact] = [
            .init(paneID: "one|same", machineID: "one", title: "Waiting", isWaiting: true),
            .init(paneID: "two|same", machineID: "two", title: "Done", isUnreadCompletion: true),
            .init(paneID: "one|worker", machineID: "one", title: "Worker", isWaiting: true, isWorker: true),
            .init(paneID: "one|shell", machineID: "one", title: "Shell", isWaiting: true, isReservedShell: true),
            .init(paneID: "removed|pane", machineID: "removed", title: "Gone", isWaiting: true)
        ]
        let input = HomeInput(machines: machines, sources: current, chats: chats)
        let value = project(input)
        #expect(value.waitingChatCount == 1)
        #expect(value.chats.count == 2)
        #expect(value.chats.map(\.isWaiting) == [true, false])
        #expect(value.chats.map(\.route) == [.chat(paneID: "one|same"), .chat(paneID: "two|same")])
        #expect(input.chats[1].isUnreadCompletion)
    }

    @Test("Fingerprint changes only with meaningful evidence, never refreshed timestamps")
    func meaningfulFingerprints() {
        let old = project(HomeInput(machines: machines, sources: [.init(id: "source", state: .current, updatedAt: now)],
                                    features: [feature(state: .blocked, evidence: "message-1")]))
        let poll = project(HomeInput(machines: machines, sources: [.init(id: "source", state: .current, updatedAt: now.addingTimeInterval(10))],
                                     features: [feature(state: .blocked, evidence: "message-1")]))
        let next = project(HomeInput(machines: machines, sources: current, features: [feature(state: .blocked, evidence: "message-2")]))
        #expect(old == poll)
        #expect(old.focus.first?.fingerprint != next.focus.first?.fingerprint)
    }

    @Test("Recap prefers current evidence and honors stable visit cutoff, timestamps and owner")
    func recapMerging() {
        let cutoff = now.addingTimeInterval(-600)
        let history = [recap(machine: "one", id: "same", seconds: -100, detail: "old"),
                       recap(machine: "two", id: "same", seconds: -100, detail: "other host"),
                       recap(id: "at-cutoff", seconds: -600), recap(id: "future", seconds: 1),
                       HomeRecapFact(machineID: "one", eventID: "undated", date: nil, title: "Unknown time")]
        let current = [recap(machine: "one", id: "same", seconds: -100, detail: "current")]
        let value = project(HomeInput(machines: machines, sources: self.current, currentRecap: current,
                                      historicalRecap: history, previousVisit: cutoff))
        #expect(value.recap.count == 2)
        #expect(value.recap.contains { $0.body.plainText.contains("current") })
        #expect(!value.recap.contains { $0.body.plainText.contains("old") })
        #expect(value.recap.map(\.id).contains(HomeIdentity.scoped(kind: "recap", machineID: "two", entityID: "same")))
        #expect(project(HomeInput(machines: machines, sources: self.current, historicalRecap: history,
                                   previousVisit: now)).recap.isEmpty)
    }

    @Test("Four machines, forty features, twenty reviews and sixty panes project without detail fetches")
    func representativeFleetPerformance() {
        let machines = (0..<4).map { HomeMachineFact(id: "machine-\($0)", name: "Host \($0)", state: .online) }
        let features = (0..<40).map { feature(machine: "machine-\($0 % 4)", id: "feature-\($0)", state: $0.isMultiple(of: 3) ? .blocked : .working) }
        let reviews = (0..<20).map { review(machine: "machine-\($0 % 4)", id: "review-\($0)", state: .ready, needsUser: true) }
        let chats = (0..<60).map { HomeChatFact(paneID: "machine-\($0 % 4)|pane-\($0)", machineID: "machine-\($0 % 4)",
                                              title: "Chat \($0)", isWaiting: $0.isMultiple(of: 2), isUnreadCompletion: !$0.isMultiple(of: 2)) }
        let input = HomeInput(machines: machines, sources: current, features: features, reviews: reviews, chats: chats)
        let expected = project(input)
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<40 { #expect(project(input) == expected) } }
        #expect(elapsed < .seconds(2))
        #expect(expected.waitingChatCount == 30)
        #expect(expected.reviewCount == 20)
        #expect(expected.focusCount == 34)
    }

    private func project(_ input: HomeInput) -> HomeSnapshot { HomeProjection.project(input, now: now, calendar: calendar) }
    private func feature(machine: String = "one", id: String = "feature", state: HomeFeatureFact.State,
                         archived: Bool = false, lead: Bool = false, stale: Bool = false, evidence: String = "message") -> HomeFeatureFact {
        .init(machineID: machine, machineName: machine, featureID: id, title: "Feature \(id)", preview: "Please review the plan.",
              state: state, isLead: lead, isArchived: archived, isStale: stale, activityAt: now.addingTimeInterval(-60), evidenceID: evidence)
    }
    private func review(machine: String = "one", id: String = "review", state: HomeReviewFact.State,
                        needsUser: Bool = false, pr: HomePullRequestIdentity? = nil) -> HomeReviewFact {
        .init(machineID: machine, machineName: machine, reviewID: id, title: "Review \(id)", pullRequest: pr,
              state: state, needsUser: needsUser, activityAt: now.addingTimeInterval(-60), evidenceID: "head-sha")
    }
    private func recap(machine: String = "one", id: String, seconds: TimeInterval, detail: String = "") -> HomeRecapFact {
        .init(machineID: machine, eventID: id, date: now.addingTimeInterval(seconds), title: "Event \(id)", detail: detail)
    }
}
