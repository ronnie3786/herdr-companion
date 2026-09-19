import Foundation
import Testing
@testable import herdr_harness_mac

/// Multi-companion discovery and selection for the report sheet.
///
/// Every case runs without a server, a window, or a sleep: capability answers
/// arrive through the collector's injected closure, and cooperative yielding
/// (not sleeping) proves that eligible requests overlap.
@Suite("Issue report machine selection")
struct IssueReportMachineSelectionTests {
    // MARK: - Selection

    @Test("The first available machine in roster order wins when nothing is remembered")
    func firstAvailableInRosterOrder() {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let checks: [String: IssueReportMachineCheck] = [
            "a": .loaded(Self.unavailable(reason: "No repository is configured.")),
            "b": .loaded(Self.available()),
            "c": .loaded(Self.available()),
        ]

        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks) == "b")
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: nil) == "b")
    }

    @Test("A remembered available machine wins over an earlier available machine")
    func rememberedAvailableWins() {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let checks: [String: IssueReportMachineCheck] = [
            "a": .loaded(Self.available()),
            "b": .loaded(Self.available()),
            "c": .loaded(Self.available()),
        ]

        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: "c") == "c")
    }

    @Test("Unavailable and unpaired remembered IDs fall back to the first available machine")
    func rememberedFallbacks() {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let checks: [String: IssueReportMachineCheck] = [
            "a": .loaded(Self.available()),
            "b": .loaded(Self.unavailable()),
            "c": .loaded(Self.available()),
        ]

        // Remembered but unavailable: take the first available peer.
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: "b") == "a")
        // Remembered but no longer paired: take the first available peer.
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: "retired") == "a")
    }

    @Test("With no available machine the remembered paired machine is kept for its reason")
    func noneAvailableKeepsRemembered() {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let checks: [String: IssueReportMachineCheck] = [
            "a": .loaded(Self.unavailable()),
            "b": .disconnected,
            "c": .failed(message: "boom"),
        ]

        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: "b") == "b")
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: "c") == "c")
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: "retired") == "a")
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks) == "a")
    }

    @Test("An empty roster has no selection")
    func emptyRosterHasNoSelection() {
        #expect(IssueReportMachineSelection.selectMachineID(roster: [], checks: [:], lastSuccessfulID: "a") == nil)
        #expect(
            IssueReportMachineSelection.selectMachineID(
                roster: [],
                checks: ["a": .loaded(Self.available())],
                lastSuccessfulID: "a"
            ) == nil
        )
    }

    @Test("Missing, checking, disconnected, failed and unavailable checks are never available")
    func availabilityMatrix() {
        #expect(!IssueReportMachineSelection.isAvailable(nil))
        #expect(!IssueReportMachineSelection.isAvailable(.checking))
        #expect(!IssueReportMachineSelection.isAvailable(.disconnected))
        #expect(!IssueReportMachineSelection.isAvailable(.failed(message: "boom")))
        #expect(!IssueReportMachineSelection.isAvailable(.loaded(Self.unavailable())))
        #expect(IssueReportMachineSelection.isAvailable(.loaded(Self.available())))

        let machines = [Self.machine("a"), Self.machine("b")]
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: [:]) == "a")
        #expect(
            IssueReportMachineSelection.selectMachineID(
                roster: machines,
                checks: ["a": .checking, "b": .disconnected]
            ) == "a"
        )
    }

    @Test("Selection is the same whatever order results were recorded in")
    func selectionIgnoresInsertionOrder() {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        var forward: [String: IssueReportMachineCheck] = [:]
        forward["a"] = .loaded(Self.unavailable())
        forward["b"] = .loaded(Self.available())
        forward["c"] = .loaded(Self.available())
        var reversed: [String: IssueReportMachineCheck] = [:]
        reversed["c"] = .loaded(Self.available())
        reversed["b"] = .loaded(Self.available())
        reversed["a"] = .loaded(Self.unavailable())

        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: forward) == "b")
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: reversed) == "b")
    }

    // MARK: - Discovery

    @Test("Disconnected machines are marked, never queried, and skipped while another is available")
    func disconnectedMachinesAreExcluded() async {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let log = FetchLog()
        let checks = await IssueReportMachineSelection.collect(
            roster: machines,
            connectedIDs: ["a", "c"]
        ) { machineID in
            await log.record(machineID)
        }

        #expect(await log.machineIDs == Set(["a", "c"]))
        #expect(checks.count == machines.count)
        #expect(checks["a"] == .loaded(Self.available()))
        #expect(checks["b"] == .disconnected)
        #expect(checks["c"] == .loaded(Self.available()))
        #expect(IssueReportMachineSelection.statusLabel(for: checks["b"]) == "Disconnected")
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks) == "a")
    }

    @Test("An all-disconnected roster is answered without a single request")
    func allDisconnectedMakesNoRequests() async {
        let machines = [Self.machine("a"), Self.machine("b")]
        let log = FetchLog()
        let checks = await IssueReportMachineSelection.collect(
            roster: machines,
            connectedIDs: []
        ) { machineID in
            await log.record(machineID)
        }

        #expect(await log.machineIDs.isEmpty)
        #expect(checks == ["a": .disconnected, "b": .disconnected])
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks) == "a")
        #expect(IssueReportMachineSelection.selectedReason(for: checks["a"]) == IssueReportMachineSelection.disconnectedMessage)
    }

    @Test("One failed check never discards the other machines' answers")
    func partialFailure() async {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let reason = "Set code_factory.repository in the private configuration (owner/repo) to file issues from the app"
        let checks = await IssueReportMachineSelection.collect(
            roster: machines,
            connectedIDs: ["a", "b", "c"]
        ) { machineID in
            switch machineID {
            case "a":
                return Self.unavailable(reason: reason)
            case "b":
                throw URLError(.cannotConnectToHost)
            default:
                return Self.available()
            }
        }

        #expect(checks.count == machines.count)
        #expect(checks["a"] == .loaded(Self.unavailable(reason: reason)))
        #expect(checks["b"] == .failed(message: IssueReportMachineSelection.unreachableMessage))
        #expect(checks["c"] == .loaded(Self.available()))
        #expect(IssueReportMachineSelection.selectedReason(for: checks["a"]) == reason)
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks) == "c")
    }

    @Test("A loaded check keeps the complete capability payload, including limits")
    func loadedCheckKeepsPayload() async {
        let machines = [Self.machine("a")]
        let capabilities = IssueReportCapabilities(
            available: false,
            repository: nil,
            reason: "No repository is configured.",
            maxAttachments: 4,
            maxAttachmentBytes: 1_048_576,
            maxTotalAttachmentBytes: 2_097_152,
            publicRepository: true
        )
        let checks = await IssueReportMachineSelection.collect(
            roster: machines,
            connectedIDs: ["a"]
        ) { _ in
            capabilities
        }

        #expect(checks["a"] == .loaded(capabilities))
    }

    @Test("Older companion servers keep the 404/426 upgrade explanation", arguments: [404, 426])
    func unsupportedServerKeepsUpgradeExplanation(status: Int) async {
        let machines = [Self.machine("a")]
        let checks = await IssueReportMachineSelection.collect(
            roster: machines,
            connectedIDs: ["a"]
        ) { _ in
            throw APIError.server(status: status, message: "raw server text")
        }

        #expect(checks["a"] == .failed(message: IssueReportMachineSelection.unsupportedServerMessage))
        #expect(
            IssueReportMachineSelection.unsupportedServerMessage
                == "This machine's companion server doesn't support reports yet. "
                + "Update the companion server to file bug reports and feature requests from the app."
        )
        #expect(IssueReportMachineSelection.selectedReason(for: checks["a"]) == IssueReportMachineSelection.unsupportedServerMessage)
        // The failed machine stays selected so the sheet can explain it.
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks) == "a")
    }

    @Test("An unreachable companion no longer invites an unverified submission")
    func unreachableCompanionWording() async {
        let machines = [Self.machine("a")]
        let checks = await IssueReportMachineSelection.collect(
            roster: machines,
            connectedIDs: ["a"]
        ) { _ in
            throw URLError(.cannotConnectToHost)
        }

        let message = IssueReportMachineSelection.unreachableMessage
        #expect(checks["a"] == .failed(message: message))
        #expect(!message.contains("still try"))
        #expect(IssueReportMachineSelection.failureMessage(for: URLError(.timedOut)) == message)
        #expect(
            IssueReportMachineSelection.failureMessage(for: APIError.noActiveConnection(machineID: "a"))
                == IssueReportMachineSelection.disconnectedMessage
        )
    }

    @Test("Initial discovery marks connected machines as checking and the rest as disconnected")
    func initialChecks() {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let checks = IssueReportMachineSelection.initialChecks(roster: machines, connectedIDs: ["b", "c"])

        #expect(checks == ["a": .disconnected, "b": .checking, "c": .checking])
        #expect(IssueReportMachineSelection.eligibleMachineIDs(roster: machines, connectedIDs: ["b", "c"]) == ["b", "c"])
        #expect(IssueReportMachineSelection.eligibleMachineIDs(roster: machines, connectedIDs: []) == [])
    }

    @Test("Every eligible capability request is launched concurrently")
    func eligibleRequestsOverlap() async {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let probe = ConcurrencyProbe(expected: machines.count)
        let checks = await IssueReportMachineSelection.collect(
            roster: machines,
            connectedIDs: ["a", "b", "c"]
        ) { machineID in
            await probe.arrive()
            await probe.depart()
            return IssueReportCapabilities(available: true, repository: "owner/\(machineID)")
        }

        #expect(await probe.peak == machines.count)
        #expect(checks.count == machines.count)
    }

    @Test("Reversed completion order cannot alter selection")
    func reversedCompletionOrderCannotAlterSelection() async {
        let machines = [Self.machine("a"), Self.machine("b"), Self.machine("c")]
        let gate = CompletionOrder()
        let collector = Task {
            await IssueReportMachineSelection.collect(
                roster: machines,
                connectedIDs: ["a", "b", "c"]
            ) { machineID in
                await gate.waitForRelease(machineID)
                return IssueReportCapabilities(available: true, repository: "owner/repo")
            }
        }

        // Released in reverse roster order. Releases are buffered, so this is
        // also valid before the concurrent requests have started.
        await gate.release("c")
        await gate.release("b")
        await gate.release("a")

        let checks = await collector.value
        #expect(await gate.requested == Set(["a", "b", "c"]))
        #expect(checks.values.allSatisfy(IssueReportMachineSelection.isAvailable))
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks) == "a")
        #expect(IssueReportMachineSelection.selectMachineID(roster: machines, checks: checks, lastSuccessfulID: "c") == "c")
    }

    // MARK: - Presentation

    @Test("Picker labels distinguish checking, unavailable, disconnected and failed checks")
    func statusLabels() {
        #expect(IssueReportMachineSelection.statusLabel(for: .checking) == "Checking…")
        #expect(IssueReportMachineSelection.statusLabel(for: .loaded(Self.available())) == nil)
        #expect(IssueReportMachineSelection.statusLabel(for: .loaded(Self.unavailable())) == "Unavailable")
        #expect(IssueReportMachineSelection.statusLabel(for: .disconnected) == "Disconnected")
        #expect(IssueReportMachineSelection.statusLabel(for: .failed(message: "boom")) == "Check failed")
        #expect(IssueReportMachineSelection.statusLabel(for: nil) == nil)
    }

    @Test("A missing server reason falls back to the [code_factory] and gh guidance")
    func missingReasonFallback() {
        let fallback = IssueReportMachineSelection.missingReasonMessage
        #expect(IssueReportMachineSelection.selectedReason(for: .loaded(Self.unavailable())) == fallback)
        #expect(IssueReportMachineSelection.selectedReason(for: .loaded(Self.unavailable(reason: "  \n "))) == fallback)
        #expect(fallback.contains("[code_factory]"))
        #expect(fallback.contains("gh"))

        let serverReason = "Set code_factory.repository in the private configuration (owner/repo) to file issues from the app"
        #expect(IssueReportMachineSelection.selectedReason(for: .loaded(Self.unavailable(reason: serverReason))) == serverReason)

        #expect(IssueReportMachineSelection.selectedReason(for: .loaded(Self.available())) == nil)
        #expect(IssueReportMachineSelection.selectedReason(for: .checking) == nil)
        #expect(IssueReportMachineSelection.selectedReason(for: nil) == nil)
        #expect(
            IssueReportMachineSelection.selectedReason(for: .failed(message: "  "))
                == IssueReportMachineSelection.unreachableMessage
        )
        #expect(IssueReportMachineSelection.selectedReason(for: .failed(message: "gh failed")) == "gh failed")
        #expect(
            IssueReportMachineSelection.selectedReason(for: .disconnected)
                == IssueReportMachineSelection.disconnectedMessage
        )
    }

    // MARK: - Fixtures

    private static func machine(_ id: String) -> HerdrMachine {
        HerdrMachine(id: id, name: id.uppercased(), urlString: "https://\(id).example.invalid")
    }

    private static func available(repository: String = "owner/repo") -> IssueReportCapabilities {
        IssueReportCapabilities(available: true, repository: repository)
    }

    private static func unavailable(reason: String? = nil) -> IssueReportCapabilities {
        IssueReportCapabilities(available: false, reason: reason)
    }
}

/// Records which machines were asked for capabilities.
private actor FetchLog {
    private(set) var machineIDs: Set<String> = []

    func record(_ machineID: String) -> IssueReportCapabilities {
        machineIDs.insert(machineID)
        return IssueReportCapabilities(available: true, repository: "owner/repo")
    }
}

/// Holds each injected request until the test releases it, buffering releases
/// that arrive first. No sleeps: every fetch returns as soon as its release is
/// recorded, in whatever order that happens to be.
private actor CompletionOrder {
    private var released: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var requested: Set<String> = []

    func waitForRelease(_ machineID: String) async {
        requested.insert(machineID)
        guard !released.contains(machineID) else { return }
        await withCheckedContinuation { continuation in
            waiters[machineID] = continuation
        }
    }

    func release(_ machineID: String) {
        released.insert(machineID)
        waiters.removeValue(forKey: machineID)?.resume()
    }
}

/// Observes how many injected capability requests are in flight at once.
///
/// Each request reports its arrival and then yields cooperatively up to a
/// bounded number of times, so a concurrent collector can start the remaining
/// requests while a sequential one can never raise `peak` above one. Nothing
/// sleeps; the bound only keeps a failing implementation from hanging.
private actor ConcurrencyProbe {
    private static let maximumYields = 1_000

    private let expected: Int
    private var active = 0
    private(set) var peak = 0

    init(expected: Int) {
        self.expected = expected
    }

    func arrive() async {
        active += 1
        peak = max(peak, active)
        guard peak < expected else { return }
        for _ in 0..<Self.maximumYields {
            await Task.yield()
            if peak >= expected { return }
        }
    }

    func depart() {
        active -= 1
    }
}
