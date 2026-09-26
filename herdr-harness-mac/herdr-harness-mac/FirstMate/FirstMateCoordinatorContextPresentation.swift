import Foundation

struct FirstMateCoordinatorContextPresentation: Equatable {
    let summary: String
    let pressure: String?
    let measurement: String?
    let policy: String
    /// The measured share of the context window, for the composer's ring.
    var fraction: Double? = nil
    /// One line for the composer: "Coordinator context 41% · plenty of room".
    /// The full summary stays in the popover and help.
    var compactLine: String = ""
    var pressureReached = false

    init(feature: FirstMateFeature, capabilityAvailable: Bool) {
        policy = "Managed handoff automatically checkpoints and starts a fresh coordinator at a safe turn boundary. Full history remains available; ordinary compaction is disabled."
        guard capabilityAvailable else {
            summary = "Coordinator context unavailable · update server"
            pressure = nil
            measurement = nil
            compactLine = summary
            return
        }
        guard feature.nativeSessionID != nil else {
            summary = "Coordinator context · new session"
            pressure = nil
            measurement = nil
            compactLine = summary
            return
        }
        guard let context = feature.coordinatorContext,
              context.nativeSessionID == feature.nativeSessionID,
              context.status == .measured else {
            summary = "Coordinator context · measurement unavailable"
            pressure = nil
            measurement = nil
            compactLine = summary
            return
        }

        if let tokens = context.tokens,
           let window = context.contextWindow,
           let measuredFraction = context.measuredFraction {
            // measuredFraction is finite and clamped before conversion to Int.
            let percent = Int((measuredFraction * 100).rounded())
            summary = "Coordinator context · \(tokens.formatted()) / \(window.formatted()) tokens (\(percent)%)"
        } else if let tokens = context.tokens {
            summary = "Coordinator context · \(tokens.formatted()) tokens · window unknown"
        } else {
            summary = "Coordinator context · measurement unavailable"
        }

        var compact = summary
        if context.tokens != nil, context.contextWindow != nil, let measuredFraction = context.measuredFraction {
            fraction = measuredFraction
            compact = "Coordinator context \(Int((measuredFraction * 100).rounded()))%"
        }
        switch context.managedHandoffPressure {
        case .approaching:
            pressure = "Approaching the managed handoff target"
            compact += " · approaching handoff"
        case .thresholdReached:
            pressure = "Managed handoff threshold reached"
            compact += " · handoff threshold reached"
            pressureReached = true
        case .belowTarget:
            if fraction != nil { compact += " · plenty of room" }
            if let target = context.handoffTargetTokens {
                pressure = "Managed handoff target \(target.formatted()) tokens"
            } else {
                pressure = nil
            }
        case .unknown:
            pressure = nil
        }

        compactLine = compact

        if let observedAt = context.observedAt,
           let date = HerdrTimestamp.date(from: observedAt) {
            measurement = "Measured \(date.formatted(date: .abbreviated, time: .shortened))"
        } else {
            measurement = nil
        }
    }
}
