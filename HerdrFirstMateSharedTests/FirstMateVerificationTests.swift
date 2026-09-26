import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate verification contract", .serialized)
@MainActor
struct FirstMateVerificationTests {
    @Test("A scoped assessment decodes with duplicate display names kept distinct")
    func decodeScopedAssessment() throws {
        let json = """
        {
          "status": "partially_verified",
          "label": "Partially verified",
          "feature_revision": 7,
          "assessed_revisions": {"ws_a": "aaaa", "ws_b": "bbbb"},
          "source_revisions": ["aaaa", "bbbb"],
          "gate_set": [
            {"label": "packages/a/Same", "package": "packages/a", "suite": "Same", "configuration": "", "outcome": "passed", "tested_revision": "aaaa", "run_id": "fmvr_one", "fresh": true, "passed_count": 3},
            {"label": "packages/b/Same (debug)", "package": "packages/b", "suite": "Same", "configuration": "debug", "outcome": "failed", "tested_revision": "aaaa", "run_id": "fmvr_one", "fresh": true, "failed_count": 2}
          ],
          "missing_suites": [{"label": "packages/a/Missing", "package": "packages/a", "suite": "Missing", "reason": "never run"}],
          "previously_green_missing": [{"label": "packages/b/Dropped (debug)", "package": "packages/b", "suite": "Dropped", "configuration": "debug"}],
          "failing_suites": [{"label": "packages/b/Same (debug)", "package": "packages/b", "suite": "Same", "configuration": "debug", "outcome": "failed", "run_id": "fmvr_one", "tested_revision": "aaaa"}],
          "stale_evidence": [{"run_id": "fmvr_zero", "workspace": "ws_a", "tested_revision": "cccc", "reason": "recorded revision cccc does not match current aaaa"}],
          "coverage_reasons": ["2 required suites lack a current passing result"],
          "evidence_present": true,
          "computed_at": "2030-01-01T12:00:00Z",
          "future_additive": {"ignored": true}
        }
        """
        let verification = try JSONDecoder().decode(FirstMateVerification.self, from: Data(json.utf8))
        #expect(verification.status == .partiallyVerified)
        #expect(verification.label == "Partially verified")
        #expect(verification.featureRevision == 7)
        #expect(verification.gateSet.count == 2)
        #expect(verification.gateSet[0].displayLabel == "packages/a/Same")
        #expect(verification.gateSet[1].displayLabel == "packages/b/Same (debug)")
        #expect(verification.gateSet[0].stableIdentity != verification.gateSet[1].stableIdentity)
        #expect(verification.gateSet[0].isPassing)
        #expect(verification.gateSet[1].isFailing)
        #expect(verification.gateSet[1].outcomeTitle == "Failed")
        #expect(verification.missingSuites.first?.reason == "never run")
        #expect(verification.previouslyGreenMissing.first?.displayLabel == "packages/b/Dropped (debug)")
        #expect(verification.staleEvidence.first?.testedRevision == "cccc")
        #expect(verification.testedRevisions == ["aaaa", "bbbb"])
        #expect(verification.computedAtDate != nil)
    }

    @Test("Unknown, absent, and empty verification states cannot become verified")
    func conservativeStatuses() throws {
        let unknownJSON = #"{"status":"future_verdict","evidence_present":true,"coverage_reasons":["newer companion status"]}"#
        let unknown = try JSONDecoder().decode(FirstMateVerification.self, from: Data(unknownJSON.utf8))
        #expect(!unknown.status.isRecognized)
        #expect(unknown.status.tone == .unavailable)
        let unknownPresentation = FirstMateVerificationPresentation(verification: unknown)
        #expect(!unknownPresentation.isVerified)
        #expect(unknownPresentation.statusTitle == "Verification unavailable")
        #expect(unknownPresentation.hasUnrecognizedStatus)
        #expect(unknownPresentation.accessibilitySummary.contains("not treated as verified"))

        let empty = try JSONDecoder().decode(FirstMateVerification.self, from: Data("{}".utf8))
        #expect(empty.isEmpty)
        #expect(empty.status == .unavailable)
        #expect(!FirstMateVerificationPresentation(verification: empty).isVerified)

        let featureJSON = #"{"id":"fmf_synthetic","title":"Synthetic","goal":"Synthetic goal","cwd":"/workspace/sample-app","status":"running","revision":1,"created_at":"2030-01-01T00:00:00Z","updated_at":"2030-01-01T00:00:00Z"}"#
        let omitted = try decodeFeature(featureJSON)
        #expect(omitted.verification == nil)
        #expect(!omitted.includesVerification)

        let emptyFeatureJSON = #"{"id":"fmf_synthetic","title":"Synthetic","goal":"Synthetic goal","cwd":"/workspace/sample-app","status":"running","revision":1,"created_at":"2030-01-01T00:00:00Z","updated_at":"2030-01-01T00:00:00Z","verification":{}}"#
        let emptyFeature = try decodeFeature(emptyFeatureJSON)
        #expect(emptyFeature.verification == nil)
        #expect(emptyFeature.includesVerification)

        let scopedFeatureJSON = #"{"id":"fmf_synthetic","title":"Synthetic","goal":"Synthetic goal","cwd":"/workspace/sample-app","status":"running","revision":1,"created_at":"2030-01-01T00:00:00Z","updated_at":"2030-01-01T00:00:00Z","verification":{"status":"verified","source_revisions":["abc123"],"gate_set":[{"label":"packages/a/One","package":"packages/a","suite":"One","outcome":"passed"}],"evidence_present":true,"computed_at":"2030-01-01T12:00:00Z"}}"#
        let scopedFeature = try decodeFeature(scopedFeatureJSON)
        #expect(scopedFeature.includesVerification)
        #expect(scopedFeature.verification?.status == .verified)
        #expect(scopedFeature.verification?.gateSet.first?.displayLabel == "packages/a/One")

        let malformedFeatureJSON = #"{"id":"fmf_synthetic","title":"Synthetic","goal":"Synthetic goal","cwd":"/workspace/sample-app","status":"running","revision":1,"created_at":"2030-01-01T00:00:00Z","updated_at":"2030-01-01T00:00:00Z","verification":{"status":"verified","gate_set":"broken"}}"#
        let malformed = try decodeFeature(malformedFeatureJSON)
        #expect(malformed.includesVerification)
        #expect(malformed.verification == nil)
    }

    @Test("Presentations name the tested revision, gate set, and every coverage gap")
    func presentationGaps() throws {
        let verified = FirstMateVerification(
            status: .verified,
            featureRevision: 3,
            sourceRevisions: ["0123456789abcdef"],
            gateSet: [
                FirstMateVerificationSuite(label: "packages/a/One", package: "packages/a", suite: "One", outcome: "passed"),
                FirstMateVerificationSuite(label: "packages/b/Two", package: "packages/b", suite: "Two", outcome: "passed"),
            ],
            evidencePresent: true,
            computedAt: "2030-01-01T12:00:00Z"
        )
        let verifiedPresentation = FirstMateVerificationPresentation(verification: verified)
        #expect(verifiedPresentation.isVerified)
        #expect(verifiedPresentation.statusTitle == "Verified")
        #expect(verifiedPresentation.testedRevisionText?.contains("0123456789ab…") == true)
        #expect(verifiedPresentation.testedRevisionAccessibilityText?.contains("0123456789abcdef") == true)
        #expect(verifiedPresentation.accessibilitySummary.contains("packages/a/One Passed"))
        #expect(verifiedPresentation.accessibilitySummary.contains("packages/b/Two Passed"))
        #expect(verifiedPresentation.gateSet.count == 2)

        let partial = FirstMateVerification(
            status: .partiallyVerified,
            sourceRevisions: ["abc123"],
            gateSet: [FirstMateVerificationSuite(label: "packages/a/One", outcome: "passed")],
            missingSuites: [FirstMateVerificationSuite(label: "packages/a/Missing", reason: "never run")],
            previouslyGreenMissing: [FirstMateVerificationSuite(
                label: "packages/b/Dropped (debug)", package: "packages/b",
                suite: "Dropped", configuration: "debug"
            )],
            evidencePresent: true
        )
        let partialPresentation = FirstMateVerificationPresentation(verification: partial)
        #expect(partialPresentation.statusTitle == "Partially verified")
        #expect(partialPresentation.accessibilitySummary.contains("Missing suites: packages/a/Missing"))
        #expect(partialPresentation.accessibilitySummary.contains("Previously passing suites dropped from the gate set: packages/b/Dropped (debug)"))

        let failed = FirstMateVerification(
            status: .failed,
            failingSuites: [FirstMateVerificationSuite(label: "packages/a/Broken", outcome: "failed")],
            evidencePresent: true
        )
        #expect(FirstMateVerificationPresentation(verification: failed)
            .accessibilitySummary.contains("Failing suites: packages/a/Broken"))

        let lastReported = FirstMateVerificationPresentation(verification: verified, isLastReported: true)
        #expect(lastReported.accessibilitySummary.contains("Last reported"))

        let noRevision = FirstMateVerificationPresentation(
            verification: FirstMateVerification(status: .verified, gateSet: [
                FirstMateVerificationSuite(label: "packages/a/One", outcome: "passed")
            ], evidencePresent: true)
        )
        #expect(!noRevision.isVerified)
        #expect(noRevision.status == .unavailable)
        #expect(noRevision.statusWasDowngraded)
        #expect(noRevision.accessibilitySummary.contains("not treated as verified"))

        let noGateSet = FirstMateVerificationPresentation(
            verification: FirstMateVerification(status: .verified, sourceRevisions: ["abc123"], evidencePresent: true)
        )
        #expect(!noGateSet.isVerified)
        #expect(noGateSet.status == .unavailable)
        #expect(noGateSet.statusWasDowngraded)

        // Assessed revisions describe the current workspace and are never
        // relabeled as tested revisions.
        let assessedOnly = FirstMateVerification(
            status: .verified, assessedRevisions: ["ws_a": "abc123"],
            gateSet: [FirstMateVerificationSuite(label: "packages/a/One", outcome: "passed")],
            evidencePresent: true
        )
        #expect(assessedOnly.testedRevisions.isEmpty)

        let absent = FirstMateVerificationPresentation(verification: nil)
        #expect(!absent.isVerified)
        #expect(absent.statusTone == .unavailable)
        #expect(absent.accessibilitySummary.contains("No structured suite evidence"))
        #expect(absent.gateSet.isEmpty)
    }

    @Test("A suite without a label still composes its package and configuration")
    func suiteLabelFallback() {
        let suite = FirstMateVerificationSuite(package: "packages/a", suite: "SuiteOne", configuration: "debug")
        #expect(suite.displayLabel == "packages/a/SuiteOne (debug)")
        let unnamed = FirstMateVerificationSuite()
        #expect(unnamed.displayLabel == "Unnamed suite")
    }

    @Test("Delayed partial acknowledgements cannot replace newer verification")
    func delayedVerificationAcknowledgement() throws {
        let store = FirstMateStore()
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.updatedAt = "2030-01-01T12:00:00Z"
        snapshot.feature.verification = FirstMateVerification(
            status: .partiallyVerified, featureRevision: 4, sourceRevisions: ["new"],
            evidencePresent: true, computedAt: "2030-01-01T12:00:00Z"
        )
        store.receive(snapshot)
        store.select(snapshot.feature.id)

        var stale = snapshot.feature
        stale.status = "paused"
        stale.updatedAt = "2030-01-01T11:00:00Z"
        stale.verification = FirstMateVerification(
            status: .verified, featureRevision: 3, sourceRevisions: ["old"],
            evidencePresent: true, computedAt: "2030-01-01T11:00:00Z"
        )
        store.receive(try partialSnapshot(stale))
        #expect(store.snapshot?.feature.status == "paused")
        #expect(store.snapshot?.feature.verification?.status == .partiallyVerified)

        // Same feature revision and a newer acknowledgement timestamp, but an
        // older computation time: the cached verdict still wins.
        var delayed = snapshot.feature
        delayed.status = "paused"
        delayed.updatedAt = "2030-01-01T12:00:01Z"
        delayed.verification = FirstMateVerification(
            status: .verified, featureRevision: 4, sourceRevisions: ["old"],
            evidencePresent: true, computedAt: "2030-01-01T11:59:00Z"
        )
        store.receive(try partialSnapshot(delayed))
        #expect(store.snapshot?.feature.verification?.status == .partiallyVerified)

        // An older companion that omits the field keeps the cached verdict.
        var omitted = snapshot.feature
        omitted.updatedAt = "2030-01-01T12:00:02Z"
        store.receive(try partialSnapshot(omitted, includeVerification: false))
        #expect(store.snapshot?.feature.verification?.status == .partiallyVerified)

        // Newer evidence replaces the cached verdict.
        var newest = snapshot.feature
        newest.updatedAt = "2030-01-01T12:05:00Z"
        newest.verification = FirstMateVerification(
            status: .verified, featureRevision: 5, sourceRevisions: ["newest"],
            evidencePresent: true, computedAt: "2030-01-01T12:05:00Z"
        )
        store.receive(try partialSnapshot(newest))
        #expect(store.snapshot?.feature.verification?.status == .verified)
    }

    @Test("A delayed full snapshot cannot resurrect a stale verified assessment")
    func delayedFullSnapshot() {
        let store = FirstMateStore()
        let base = FirstMateDemo.features(step: 3)[0]
        store.receive(base)
        store.select(base.feature.id)
        #expect(store.snapshot?.feature.verification?.status == .verified)

        var newer = base
        newer.feature.updatedAt = "2030-01-02T00:00:00Z"
        newer.feature.verification = FirstMateVerification(
            status: .partiallyVerified, featureRevision: base.feature.revision,
            sourceRevisions: ["newer"], evidencePresent: true, computedAt: "2030-01-02T00:00:00Z"
        )
        store.receive(newer)
        #expect(store.snapshot?.feature.verification?.status == .partiallyVerified)

        var delayed = base
        delayed.feature.updatedAt = "2030-01-01T00:00:00Z"
        delayed.feature.verification = FirstMateVerification(
            status: .verified, featureRevision: base.feature.revision,
            sourceRevisions: ["older"], evidencePresent: true, computedAt: "2030-01-01T00:00:00Z"
        )
        store.receive(delayed)
        #expect(store.snapshot?.feature.verification?.status == .partiallyVerified)
    }

    @Test("An authoritative unavailable full snapshot downgrades cached verified evidence")
    func authoritativeUnavailableDowngrades() {
        let store = FirstMateStore()
        let base = FirstMateDemo.features(step: 3)[0]
        store.receive(base)
        store.select(base.feature.id)
        #expect(store.snapshot?.feature.verification?.status == .verified)

        // An explicit empty field in a newer full snapshot is an authoritative
        // "reported but unavailable", not a reason to keep the cached green.
        var emptied = base
        emptied.feature.updatedAt = "2030-01-02T00:00:00Z"
        emptied.feature.verification = nil
        emptied.feature.includesVerification = true
        store.receive(emptied)
        #expect(store.snapshot?.feature.verification?.status == .unavailable)

        store.receive(base)
        #expect(store.snapshot?.feature.verification?.status == .unavailable)

        // A newer authoritative response restores the verified assessment...
        var restored = base
        restored.feature.updatedAt = "2030-01-04T00:00:00Z"
        store.receive(restored)
        #expect(store.snapshot?.feature.verification?.status == .verified)

        // ...and a still-newer full snapshot from an older companion that
        // omits the field again downgrades it.
        var omitted = base
        omitted.feature.updatedAt = "2030-01-05T00:00:00Z"
        omitted.feature.includesVerification = false
        store.receive(omitted)
        #expect(store.snapshot?.feature.verification?.status == .unavailable)
    }

    @Test("The synthetic demo carries every verification presentation state")
    func demoStates() throws {
        let steps = (0...5).map { FirstMateDemo.features(step: $0)[0].feature.verification }
        #expect(steps[0] == nil)
        #expect(steps[1]?.status == .partiallyVerified)
        #expect(steps[1]?.missingSuites.isEmpty == false)
        #expect(steps[1]?.previouslyGreenMissing.isEmpty == false)
        #expect(steps[2]?.status == .failed)
        #expect(steps[2]?.failingSuites.isEmpty == false)
        #expect(steps[3]?.status == .verified)
        #expect(steps[3]?.gateSet.count == 4)
        #expect(steps[3]?.missingSuites.isEmpty == true)
        #expect(steps[3]?.previouslyGreenMissing.isEmpty == true)
        #expect(steps[4]?.status == .partiallyVerified)
        #expect(steps[4]?.staleEvidence.isEmpty == false)
        #expect(steps[5]?.status == .verified)
        let verified = try #require(steps[3])
        #expect(!verified.testedRevisions.isEmpty)
        #expect(verified.gateSet.allSatisfy { $0.isPassing })
    }

    // MARK: - Helpers

    private func decodeFeature(_ json: String) throws -> FirstMateFeature {
        try JSONDecoder().decode(FirstMateFeature.self, from: Data(json.utf8))
    }

    private func partialSnapshot(_ feature: FirstMateFeature, includeVerification: Bool = true) throws -> FirstMateSnapshot {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feature)) as? [String: Any])
        if !includeVerification { object.removeValue(forKey: "verification") }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "feature": object])
        let snapshot = try JSONDecoder().decode(FirstMateSnapshot.self, from: data)
        #expect(!snapshot.hasDetails)
        return snapshot
    }
}
