import SwiftUI

/// Type-erased wall-clock time source for `HerdrHudSessionMetadataClock`.
///
/// Wraps any Swift `Clock` (production: `ContinuousClock`; tests: a manual clock) behind a plain,
/// non-generic type. It only exposes "what wall-clock date is it right now" and "suspend for this many
/// seconds," both derived from the wrapped clock's own progress relative to a fixed reference point
/// captured once at construction -- so advancing a manual test clock moves the reported date forward
/// without any real waiting, while production (backed by `ContinuousClock`) tracks real elapsed time.
struct HerdrHudMetadataTimeSource: Sendable {
    private let dateProvider: @Sendable () -> Date
    private let sleeper: @Sendable (Duration) async throws -> Void

    init<ClockType: Clock>(_ clock: ClockType) where ClockType.Duration == Duration {
        let referenceInstant = clock.now
        let referenceDate = Date()
        dateProvider = {
            referenceDate.addingTimeInterval(referenceInstant.duration(to: clock.now).timeIntervalValue)
        }
        sleeper = { duration in
            try await clock.sleep(for: duration)
        }
    }

    /// Production default: a real, monotonically ticking clock. Fixed once as a process-wide `static
    /// let`, so its reference point never resets -- reconstructing a `HerdrHudMetadataTimeSource` from
    /// a *fresh* clock on every use would re-anchor `referenceDate` and silently discard elapsed time,
    /// which is exactly what tests must avoid too (build a test's time source once and reuse the same
    /// value, never rebuild it from the clock inside a view's `body`).
    static let live = HerdrHudMetadataTimeSource(ContinuousClock())

    func now() -> Date { dateProvider() }

    func sleep(for interval: TimeInterval) async throws {
        try await sleeper(.seconds(max(interval, 0)))
    }
}

private extension Duration {
    var timeIntervalValue: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

extension EnvironmentValues {
    @Entry var herdrHudShowsModel = true
    @Entry var herdrHudMetadataTimeSource = HerdrHudMetadataTimeSource.live
    /// Render tests have no host accessibility setting to influence, and the
    /// system `accessibilityReduceMotion` value is read-only to app code. This
    /// optional override lets a fixture exercise the reduced-motion branch
    /// while production stays on the system value (nil).
    @Entry var herdrHudReduceMotionOverride: Bool? = nil
}

/// One shared time source supplies the phase to the entire stack, including overflow rows. Uses a
/// background task (instead of `TimelineView`) so tests can inject a manual clock via
/// `herdrHudMetadataTimeSource` and skip real waiting; production is unaffected because the environment
/// default wraps `ContinuousClock`.
struct HerdrHudSessionMetadataClock: ViewModifier {
    @Environment(\.herdrHudMetadataTimeSource) private var timeSource
    @State private var tick = 0

    func body(content: Content) -> some View {
        let showsModel = HerdrHudSessionMetadataCycle.showsModel(at: timeSource.now())
        // `body` must actually read `tick` for SwiftUI to reliably re-render this modifier (and repropagate
        // the recomputed environment value to descendants) each time `run()` increments it -- a write to an
        // unread `@State` property is not a reliable re-render trigger here.
        _ = tick
        return content
            .environment(\.herdrHudShowsModel, showsModel)
            .task { await run() }
    }

    private func run() async {
        while !Task.isCancelled {
            let now = timeSource.now()
            let wait = HerdrHudSessionMetadataCycle.timeUntilNextBoundary(after: now)
            do {
                try await timeSource.sleep(for: wait)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            tick &+= 1
        }
    }
}
