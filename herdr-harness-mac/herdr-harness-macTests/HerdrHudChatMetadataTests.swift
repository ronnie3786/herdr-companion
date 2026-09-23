import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("HUD chat metadata accumulator")
struct HerdrHudChatMetadataTests {
    private typealias Accumulator = HerdrHudChatMetadataAccumulator
    private typealias Sample = HerdrHudChatMetadataAccumulator.RunSample

    private func reconciled(
        machineID: String = "alpha",
        rootRunID: String = "root-1",
        runs: [(id: String, cost: Double?, model: String?)]
    ) -> Accumulator {
        var accumulator = Accumulator()
        accumulator.reconcile(
            machineID: machineID,
            rootRunID: rootRunID,
            expectedTurnCount: runs.count,
            samples: runs.map { Sample(id: $0.id, costUSD: $0.cost, modelName: $0.model) }
        )
        return accumulator
    }

    @Test("Repeated observations of one run replace instead of adding")
    func repeatedObservationsReplace() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 1.00, modelName: "Sonnet 4.5")
        )
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 1.00, modelName: "Sonnet 4.5")
        )
        accumulator.updateObservedRun(id: "run-1", costUSD: 1.50, modelName: "Sonnet 4.5")

        #expect(accumulator.observedRunCount == 1)
        #expect(accumulator.totalCostUSD == 1.50)
        #expect(accumulator.metadata.cost == "$1.50")
    }

    @Test("A newer accepted turn seals the previous one and the total is cumulative")
    func cumulativeAcrossAcceptedTurns() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 1.00, modelName: "Sonnet 4.5")
        )
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 2,
            sample: Sample(id: "run-2", costUSD: 2.25, modelName: "Opus 4.5")
        )
        accumulator.updateObservedRun(id: "run-2", costUSD: 2.50, modelName: "Opus 4.5")

        #expect(accumulator.observedRunCount == 2)
        #expect(accumulator.totalCostUSD == 3.50)
        #expect(accumulator.metadata.cost == "$3.50")
        #expect(accumulator.metadata.modelName == "Opus 4.5")
    }

    @Test("Zero, tiny, and large totals use the shared cost formatter")
    func totalsUseSharedFormatting() {
        #expect(reconciled(runs: [("run-1", 0, nil)]).metadata.cost == "$0.00")
        #expect(reconciled(runs: [("run-1", 0.004, nil)]).metadata.cost == "<$0.01")
        #expect(reconciled(runs: [("run-1", 134.2, nil)]).metadata.cost == "$134")
    }

    @Test("Missing cost reports unknown until every observed turn is known")
    func missingCostIsUnknown() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: nil, modelName: "Sonnet 4.5")
        )
        #expect(accumulator.totalCostUSD == nil)
        #expect(accumulator.metadata.cost == nil)
        #expect(accumulator.metadata.modelName == "Sonnet 4.5")

        accumulator.updateObservedRun(id: "run-1", costUSD: 1.25, modelName: nil)
        #expect(accumulator.totalCostUSD == 1.25)
        #expect(accumulator.metadata.cost == "$1.25")

        let partial = reconciled(runs: [("run-1", 1.00, nil), ("run-2", nil, nil)])
        #expect(partial.observedRunCount == 2)
        #expect(partial.hasEstablishedCoverage)
        #expect(!partial.isComplete)
        #expect(partial.totalCostUSD == nil)
        #expect(partial.metadata.cost == nil)
    }

    @Test("Negative, non-finite, and sentinel values never fabricate a total")
    func invalidValuesNeverFabricateATotal() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: -4, modelName: " default ")
        )
        #expect(accumulator.totalCostUSD == nil)
        #expect(accumulator.metadata.cost == nil)
        #expect(accumulator.metadata.modelName == nil)

        accumulator.updateObservedRun(id: "run-1", costUSD: .nan, modelName: "unknown")
        accumulator.updateObservedRun(id: "run-1", costUSD: .infinity, modelName: "Unknown")
        #expect(accumulator.totalCostUSD == nil)
        #expect(accumulator.metadata.modelName == nil)

        accumulator.updateObservedRun(id: "run-1", costUSD: 0.009, modelName: "Sonnet 4.5")
        #expect(accumulator.metadata.cost == "<$0.01")
        #expect(accumulator.metadata.modelName == "Sonnet 4.5")
    }

    @Test("The last known same-run values survive a transient nil sample")
    func lastKnownValuesSurviveTransientNil() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 1.00, modelName: "Sonnet 4.5")
        )
        accumulator.updateObservedRun(id: "run-1", costUSD: nil, modelName: nil)

        #expect(accumulator.totalCostUSD == 1.00)
        #expect(accumulator.metadata.modelName == "Sonnet 4.5")
    }

    @Test("A stale sample for a sealed run is ignored")
    func staleSampleForSealedRunIsIgnored() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 1.00, modelName: "Sonnet 4.5")
        )
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 2,
            sample: Sample(id: "run-2", costUSD: 2.00, modelName: "Opus 4.5")
        )
        accumulator.updateObservedRun(id: "run-1", costUSD: 99, modelName: "Ignored")

        #expect(accumulator.totalCostUSD == 3.00)
        #expect(accumulator.metadata.modelName == "Opus 4.5")
    }

    @Test("The newest accepted turn owns the model and a missing model is not backfilled")
    func newestTurnOwnsTheModel() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 1.00, modelName: "Sonnet 4.5")
        )
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 2,
            sample: Sample(id: "run-2", costUSD: 2.00, modelName: "Opus 4.5")
        )
        #expect(accumulator.metadata.modelName == "Opus 4.5")

        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 3,
            sample: Sample(id: "run-3", costUSD: 3.00, modelName: "default")
        )
        #expect(accumulator.metadata.modelName == nil)
    }

    @Test("Reconcile replaces live samples rather than adding them")
    func reconcileReplacesLiveSamples() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 5.00, modelName: nil)
        )
        accumulator.reconcile(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 2,
            samples: [
                Sample(id: "run-1", costUSD: 1.00, modelName: nil),
                Sample(id: "run-2", costUSD: 2.00, modelName: nil),
            ]
        )

        #expect(accumulator.observedRunCount == 2)
        #expect(accumulator.totalCostUSD == 3.00)
    }

    @Test("Reconcile counts repeated run IDs once and keeps the last sample")
    func reconcileDeduplicatesRunIDs() {
        var accumulator = Accumulator()
        accumulator.reconcile(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 2,
            samples: [
                Sample(id: "run-1", costUSD: 1.00, modelName: nil),
                Sample(id: "run-2", costUSD: 2.00, modelName: nil),
                Sample(id: "run-1", costUSD: 3.00, modelName: nil),
            ]
        )

        #expect(accumulator.observedRunCount == 2)
        #expect(accumulator.hasEstablishedCoverage)
        #expect(accumulator.totalCostUSD == 5.00)
    }

    @Test("More than twenty turns stay in the aggregate after the transcript cap")
    func aggregateSurvivesTranscriptCap() {
        var accumulator = Accumulator()
        for index in 1...30 {
            accumulator.recordAcceptedRun(
                machineID: "alpha",
                rootRunID: "root-1",
                expectedTurnCount: index,
                sample: Sample(id: "run-\(index)", costUSD: 0.01, modelName: nil)
            )
        }

        #expect(accumulator.observedRunCount == 30)
        #expect(accumulator.hasEstablishedCoverage)
        #expect(accumulator.isComplete)
        #expect(accumulator.metadata.cost == "$0.30")
    }

    @Test("An unproven or partial turn count keeps the cost unknown")
    func unprovenCoverageKeepsCostUnknown() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 2,
            sample: Sample(id: "run-1", costUSD: 1.00, modelName: nil)
        )
        #expect(accumulator.observedRunCount == 1)
        #expect(!accumulator.hasEstablishedCoverage)
        #expect(!accumulator.isComplete)
        #expect(accumulator.totalCostUSD == nil)

        var unproven = Accumulator()
        unproven.reconcile(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: nil,
            samples: [Sample(id: "run-1", costUSD: 1.00, modelName: nil)]
        )
        #expect(!unproven.hasEstablishedCoverage)
        #expect(unproven.totalCostUSD == nil)
    }

    @Test("Changing machines or roots resets the aggregate for the same run ID")
    func identityReplacementResetsSamples() {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "same-run", costUSD: 1.00, modelName: "Alpha Model")
        )
        accumulator.recordAcceptedRun(
            machineID: "beta",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "same-run", costUSD: 2.00, modelName: "Beta Model")
        )

        #expect(accumulator.isScoped(to: .init(machineID: "beta", rootRunID: "root-1")))
        #expect(accumulator.totalCostUSD == 2.00)
        #expect(accumulator.metadata.modelName == "Beta Model")

        accumulator.recordAcceptedRun(
            machineID: "beta",
            rootRunID: "root-2",
            expectedTurnCount: 1,
            sample: Sample(id: "same-run", costUSD: 3.00, modelName: "Gamma Model")
        )
        #expect(accumulator.totalCostUSD == 3.00)
        #expect(accumulator.metadata.modelName == "Gamma Model")
        #expect(accumulator.observedRunCount == 1)
    }

    @Test("Two accumulators for machines that share a display label stay independent")
    func duplicateDisplayLabelsStayIndependent() {
        var first = Accumulator()
        first.recordAcceptedRun(
            machineID: "machine-a",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "agr_000000000001", costUSD: 1.25, modelName: "Sonnet 4.5")
        )
        var second = Accumulator()
        second.recordAcceptedRun(
            machineID: "machine-b",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "agr_000000000001", costUSD: 9.75, modelName: "Opus 4.5")
        )

        #expect(first.totalCostUSD == 1.25)
        #expect(second.totalCostUSD == 9.75)
        #expect(first.metadata.modelName == "Sonnet 4.5")
        #expect(second.metadata.modelName == "Opus 4.5")
    }

    @Test("The aggregate encodes and decodes through persistence")
    func persistenceRoundTrip() throws {
        var accumulator = Accumulator()
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 1,
            sample: Sample(id: "run-1", costUSD: 0.42, modelName: "Sonnet 4.5")
        )
        accumulator.recordAcceptedRun(
            machineID: "alpha",
            rootRunID: "root-1",
            expectedTurnCount: 2,
            sample: Sample(id: "run-2", costUSD: 1.00, modelName: "Opus 4.5")
        )

        let data = try JSONEncoder().encode(accumulator)
        let decoded = try JSONDecoder().decode(Accumulator.self, from: data)

        #expect(decoded == accumulator)
        #expect(decoded.metadata == accumulator.metadata)
        #expect(decoded.metadata.cost == "$1.42")
        #expect(decoded.metadata.modelName == "Opus 4.5")
    }

    @Test("Legacy and malformed payloads decode without fabricating a total")
    func lenientDecoding() throws {
        let empty = try JSONDecoder().decode(Accumulator.self, from: Data("{}".utf8))
        #expect(empty.totalCostUSD == nil)
        #expect(empty.metadata.label(showsModel: true) == nil)
        #expect(empty.metadata.label(showsModel: false) == nil)

        let malformed = try JSONDecoder().decode(
            Accumulator.self,
            from: Data(
                #"{"machineID":"alpha","rootRunID":"root-1","knownTurnCount":2,"latestRunID":"run-2","latestRunCostUSD":-4,"sealedCostUSD":-1,"sealedKnownRunCount":-3,"sealedUnknownRunCount":-2}"#
                    .utf8
            )
        )
        #expect(malformed.observedRunCount == 1)
        #expect(malformed.totalCostUSD == nil)
        #expect(malformed.metadata.cost == nil)
    }
}
