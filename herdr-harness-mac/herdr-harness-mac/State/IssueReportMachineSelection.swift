import Foundation

/// Result of one paired companion's report-capabilities check.
///
/// The cases are deliberately distinct so the report sheet can say whether a
/// machine was checked, skipped because it is disconnected, answered, or failed
/// to answer. `.loaded` keeps the complete `IssueReportCapabilities` payload —
/// including an unavailable response and its server-provided reason — so the
/// UI can show exactly what the companion reported and nothing invented.
enum IssueReportMachineCheck: Equatable, Sendable {
    /// The machine is connected and its capabilities request is in flight.
    case checking
    /// The machine is paired but has no live connection, so no request is made.
    case disconnected
    /// The companion answered with its full capability payload.
    case loaded(IssueReportCapabilities)
    /// The request failed before a payload arrived; the message is ready to show.
    case failed(message: String)
}

/// Discovery and selection of the companion that files an issue report.
///
/// The report sheet has one draft but several paired companions, and only some
/// of them can file GitHub issues. This utility owns the parts worth testing on
/// their own: which machines are asked, how their concurrent answers are
/// collected, which machine ends up selected, and the short labels and reasons
/// the picker shows. It performs no I/O: `collect` receives the capabilities
/// call through a closure and only `HerdrAppModel` supplies the real one.
enum IssueReportMachineSelection {
    // MARK: - Messages

    /// 404/426 explanation, preserved from the original capability check: an
    /// older companion server rejects the capabilities route or advertises no
    /// report support, and the sheet cannot file anything through it.
    static let unsupportedServerMessage = "This machine's companion server doesn't support reports yet. "
        + "Update the companion server to file bug reports and feature requests from the app."

    /// Fallback when a companion could not be checked at all. The wording that
    /// invited a submission whose availability was never verified is gone on
    /// purpose: a report is only filed through a companion that answered.
    static let unreachableMessage = "Couldn't reach this machine's companion server to check report settings. "
        + "Choose another machine, or reconnect this one and try again."

    /// Fallback when an unavailable companion sent no reason. The server checks
    /// the configured repository, not the GitHub login: a repository under
    /// `[code_factory]` still needs a `gh` login with access to it when a
    /// report is submitted.
    static let missingReasonMessage = "Reports aren't configured on this companion server yet. "
        + "Set the repository under [code_factory] in its private configuration; "
        + "filing also needs a gh login with access to that repository."

    /// Shown when a paired machine is not connected, so its report settings
    /// were never checked.
    static let disconnectedMessage = "This machine isn't connected, so its report settings weren't checked. "
        + "Connect it and try again."

    // MARK: - Selection

    /// Picks the machine whose companion should file the report.
    ///
    /// - The remembered machine wins when it is still paired and available.
    /// - Otherwise the first available machine in roster order wins, so the
    ///   result does not depend on which request answered first or on the app's
    ///   current machine scope.
    /// - When nothing is available, the remembered machine is kept if it is
    ///   still paired; otherwise the first paired machine is kept, so the sheet
    ///   can still explain why that companion cannot file. An empty roster has
    ///   no selection.
    static func selectMachineID(
        roster: [HerdrMachine],
        checks: [String: IssueReportMachineCheck],
        lastSuccessfulID: String? = nil
    ) -> String? {
        let pairedIDs = uniqueMachineIDs(in: roster)
        if let lastSuccessfulID,
           pairedIDs.contains(lastSuccessfulID),
           isAvailable(checks[lastSuccessfulID]) {
            return lastSuccessfulID
        }
        if let availableID = pairedIDs.first(where: { isAvailable(checks[$0]) }) {
            return availableID
        }
        if let lastSuccessfulID, pairedIDs.contains(lastSuccessfulID) {
            return lastSuccessfulID
        }
        return pairedIDs.first
    }

    /// Whether a check proves the companion can file reports. Missing,
    /// checking, disconnected, failed and unavailable checks never do.
    static func isAvailable(_ check: IssueReportMachineCheck?) -> Bool {
        guard let check, case let .loaded(capabilities) = check else { return false }
        return capabilities.available
    }

    // MARK: - Discovery

    /// The first state of a discovery pass: connected machines are being
    /// checked, every other paired machine is disconnected without a request.
    static func initialChecks(
        roster: [HerdrMachine],
        connectedIDs: Set<String>
    ) -> [String: IssueReportMachineCheck] {
        var checks: [String: IssueReportMachineCheck] = [:]
        for machineID in uniqueMachineIDs(in: roster) {
            checks[machineID] = connectedIDs.contains(machineID) ? .checking : .disconnected
        }
        return checks
    }

    /// Machine IDs to ask, in roster order and without duplicates.
    static func eligibleMachineIDs(
        roster: [HerdrMachine],
        connectedIDs: Set<String>
    ) -> [String] {
        uniqueMachineIDs(in: roster).filter { connectedIDs.contains($0) }
    }

    /// Asks every paired, connected machine for its report capabilities at the
    /// same time and returns one check per roster entry.
    ///
    /// Each request catches its own failure, so one unreachable companion never
    /// discards the answers from the others. Paired but disconnected machines
    /// are reported `.disconnected` without a request. Results are keyed by
    /// machine ID; roster order decides selection, not completion order.
    static func collect(
        roster: [HerdrMachine],
        connectedIDs: Set<String>,
        fetchCapabilities: @escaping @Sendable (String) async throws -> IssueReportCapabilities
    ) async -> [String: IssueReportMachineCheck] {
        var checks = initialChecks(roster: roster, connectedIDs: connectedIDs)
        let eligibleIDs = eligibleMachineIDs(roster: roster, connectedIDs: connectedIDs)
        guard !eligibleIDs.isEmpty else { return checks }
        await withTaskGroup(of: (String, IssueReportMachineCheck).self) { group in
            for machineID in eligibleIDs {
                group.addTask {
                    do {
                        let capabilities = try await fetchCapabilities(machineID)
                        return (machineID, .loaded(capabilities))
                    } catch {
                        return (machineID, .failed(message: failureMessage(for: error)))
                    }
                }
            }
            for await (machineID, check) in group {
                checks[machineID] = check
            }
        }
        return checks
    }

    // MARK: - Presentation

    /// Short suffix shown in the machine picker beside a machine's name, or nil
    /// to show the plain name. Only available machines keep their name alone.
    static func statusLabel(for check: IssueReportMachineCheck?) -> String? {
        guard let check else { return nil }
        switch check {
        case .checking: return "Checking…"
        case .disconnected: return "Disconnected"
        case let .loaded(capabilities): return capabilities.available ? nil : "Unavailable"
        case .failed: return "Check failed"
        }
    }

    /// The reason shown beneath the picker for the selected machine, or nil
    /// when there is nothing useful to say.
    ///
    /// An unavailable `.loaded` machine uses the server's own reason word for
    /// word, or the `[code_factory]` guidance when the server sent none. A
    /// `.failed` machine uses the message `collect` mapped from the error. A
    /// disconnected machine explains that it was never checked. Available and
    /// checking machines have no reason to show.
    static func selectedReason(for check: IssueReportMachineCheck?) -> String? {
        guard let check else { return nil }
        switch check {
        case .checking:
            return nil
        case .disconnected:
            return disconnectedMessage
        case let .loaded(capabilities):
            guard !capabilities.available else { return nil }
            return normalized(capabilities.reason) ?? missingReasonMessage
        case let .failed(message):
            return normalized(message) ?? unreachableMessage
        }
    }

    /// The message shown when a check fails before the companion answers.
    ///
    /// The 404/426 wording is the upgrade explanation the capability check has
    /// always produced. Everything else is a dead end on purpose: the sheet
    /// must not invite a submission whose availability was never verified.
    static func failureMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else { return unreachableMessage }
        switch apiError {
        case let .server(status, message):
            if status == 404 || status == 426 { return unsupportedServerMessage }
            return normalized(message) ?? unreachableMessage
        case .noActiveConnection:
            return disconnectedMessage
        default:
            return unreachableMessage
        }
    }

    // MARK: - Helpers

    /// Roster IDs in their original order, with duplicates removed. A duplicate
    /// entry never causes a second request or a second candidate.
    private static func uniqueMachineIDs(in roster: [HerdrMachine]) -> [String] {
        var seen: Set<String> = []
        return roster.map(\.id).filter { seen.insert($0).inserted }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
