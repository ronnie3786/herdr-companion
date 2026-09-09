import Foundation

struct PiToolInvocation: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case waiting
        case running
        case succeeded
        case failed
    }

    let id: String
    let callID: String
    private let cachedArgumentsDisplayString: String?
    private let cachedResultDisplayString: String?
    // Running structured payloads are formatted only when a card is opened,
    // not on every streaming update of a collapsed tool group.
    var argumentsDisplayString: String? {
        cachedArgumentsDisplayString ?? Self.displayString(for: arguments)
    }
    var resultDisplayString: String? {
        cachedResultDisplayString ?? Self.displayString(for: result)
    }
    var name: String
    var arguments: PiJSONValue?
    var result: PiJSONValue?
    let resultArtifact: AgentResultArtifact?
    var status: Status
    var startedAt: Date?
    var finishedAt: Date?

    init(
        id: String,
        callID: String,
        name: String,
        arguments: PiJSONValue?,
        result: PiJSONValue?,
        status: Status,
        startedAt: Date?,
        finishedAt: Date?,
        resultArtifact: AgentResultArtifact? = nil
    ) {
        self.id = id
        self.callID = callID
        let isTerminal = status == .succeeded || status == .failed
        self.cachedArgumentsDisplayString = isTerminal ? Self.displayString(for: arguments) : nil
        self.cachedResultDisplayString = isTerminal ? Self.displayString(for: result) : nil
        self.name = name
        self.arguments = arguments
        self.result = result
        self.resultArtifact = resultArtifact ?? AgentResultArtifact(piMetadata: result?["details"]?["artifact"])
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    private static func displayString(for value: PiJSONValue?) -> String? {
        guard let value else { return nil }
        let display = value.displayString
        let byteCount = display.utf8.count
        guard byteCount > 65_536 else { return display }

        var prefixEnd = display.startIndex
        var prefixByteCount = 0
        for index in display.indices {
            let nextIndex = display.index(after: index)
            let characterByteCount = display[index..<nextIndex].utf8.count
            guard prefixByteCount + characterByteCount <= 65_536 else { break }
            prefixByteCount += characterByteCount
            prefixEnd = nextIndex
        }
        let totalKB = byteCount / 1_024
        return String(display[..<prefixEnd]) + "\n… (truncated, \(totalKB) KB total)"
    }
}
