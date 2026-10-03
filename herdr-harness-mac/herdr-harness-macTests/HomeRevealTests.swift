import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Home destination reveal identity")
struct HomeRevealTests {
    @Test("Same entity IDs never match another owner or destination type")
    func exactOwner() {
        let request = HomeRevealRequest(target: .watcher(machineID: "alpha", watcherID: "same"), ownerName: "Alpha")
        let wrongOwner: Set<HomeRevealRequest.Target> = [.watcher(machineID: "beta", watcherID: "same"),
                                                        .review(machineID: "alpha", reviewID: "same")]
        let ledger = HomeRevealLedger()
        #expect(ledger.resolve(request, isReady: true, available: wrongOwner) == .missing(request.missingMessage))
        #expect(ledger.resolve(request, isReady: true, available: wrongOwner.union([request.target])) == .available)
    }

    @Test("Loading waits; a missing target retains its exact original owner")
    func deferredThenMissing() {
        let request = HomeRevealRequest(target: .review(machineID: "alpha-id", reviewID: "review-id"), ownerName: "Desk")
        let ledger = HomeRevealLedger()
        #expect(ledger.resolve(request, isReady: false, available: []) == .waiting)
        #expect(ledger.resolve(request, isReady: true, available: []) == .missing(request.missingMessage))
        #expect(request.missingMessage.contains("review-id"))
        #expect(request.missingMessage.contains("Desk (alpha-id)"))
    }

    @Test("A request applies once, but another click on the same item reveals again")
    func receipt() {
        let target = HomeRevealRequest.Target.machine(machineID: "alpha")
        let first = HomeRevealRequest(target: target)
        let second = HomeRevealRequest(target: target)
        var ledger = HomeRevealLedger()
        #expect(ledger.resolve(first, isReady: true, available: [target]) == .available)
        ledger.markHandled(first)
        #expect(ledger.resolve(first, isReady: true, available: [target]) == .alreadyHandled)
        #expect(ledger.resolve(second, isReady: true, available: [target]) == .available)
        #expect(first.id != second.id)
    }
}
