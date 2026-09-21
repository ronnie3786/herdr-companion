import Observation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Shared HUD metadata clock", .serialized)
@MainActor
struct HudSessionMetadataClockTests {
    @Test("Every five-second boundary has one phase, independent of mounting time")
    func phaseBoundaries() {
        func phase(_ seconds: TimeInterval) -> Bool {
            HerdrHudSessionMetadataCycle.showsModel(at: .init(timeIntervalSince1970: seconds))
        }
        #expect(phase(0))
        #expect(phase(4.999))
        #expect(!phase(5))
        #expect(!phase(9.999))
        #expect(phase(10))
        #expect(phase(1_800_000_002))
        #expect(!phase(1_800_000_007))
        let schedule = PeriodicTimelineSchedule(from: HerdrHudSessionMetadataCycle.epoch, by: HerdrHudSessionMetadataCycle.interval)
        let dates = Array(schedule.entries(from: .init(timeIntervalSince1970: 1_800_000_007), mode: .normal).prefix(3))
        #expect(dates.count == 3)
        #expect(dates[1].timeIntervalSince(dates[0]) == 5)
        #expect(dates[2].timeIntervalSince(dates[1]) == 5)
        #expect(dates.allSatisfy { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 5) == 0 })
    }

    @Test("Late and recreated rows join the same live clock without resetting it")
    func lateMounts() async throws {
        let mounts = Mounts()
        let log = PhaseLog()
        let clock = ManualHerdrHudMetadataClock()
        let timeSource = HerdrHudMetadataTimeSource(clock)

        func settle(maxAttempts: Int = 200, until condition: () -> Bool = { false }) async {
            for _ in 0..<maxAttempts {
                if condition() { return }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        // Advances the manual clock toward a target in chunks smaller than
        // `HerdrHudSessionMetadataCycle.interval` (5s). A single instantaneous jump across two or more phase
        // boundaries would let SwiftUI observe only the *net* result of all of them at once (or nothing at all,
        // if an even number of boundaries were skipped) -- nothing forces an intermediate render between two
        // virtual instants the way real, continuously elapsing time would. Chunking below the interval
        // guarantees at most one boundary per chunk. After each chunk, wait specifically for the "first" probe's
        // logged phase to match what `showsModel(at:)` says it should now be -- an already-correct phase
        // returns immediately (most chunks cross no boundary), while a chunk that did cross one gets a real,
        // generous budget to flush through AppKit's offscreen render pipeline before the next chunk's jump can
        // run past it.
        func advanceAcrossBoundaries(totalMilliseconds: Int, chunkMilliseconds: Int = 1_000) async {
            var remaining = totalMilliseconds
            while remaining > 0 {
                let step = min(chunkMilliseconds, remaining)
                clock.advance(by: .milliseconds(step))
                remaining -= step
                let expected = HerdrHudSessionMetadataCycle.showsModel(at: timeSource.now())
                await settle(until: { log.phases["first"] == expected })
            }
        }

        _ = try await HerdrRenderHarness.render("hud-shared-clock-test.png", size: CGSize(width: 240, height: 90), afterSettling: {
            #expect(log.phases["first"] != nil)

            clock.advance(by: .milliseconds(1250))
            mounts.showsLate = true
            await settle(until: { log.phases["late"] != nil })

            clock.advance(by: .milliseconds(100))
            await settle(until: { log.phases["late"] == log.phases["first"] })
            #expect(log.phases["late"] == log.phases["first"])

            await advanceAcrossBoundaries(totalMilliseconds: 5_250)
            await settle(until: { (log.changes["first"] ?? 0) >= 2 && (log.changes["late"] ?? 0) >= 2 })
            #expect((log.changes["first"] ?? 0) >= 2)
            #expect((log.changes["late"] ?? 0) >= 2)
            #expect(log.phases["late"] == log.phases["first"])

            mounts.revision += 1
            clock.advance(by: .milliseconds(100))
            await settle(until: { log.phases["late"] == log.phases["first"] })
            #expect(log.phases["late"] == log.phases["first"])
        }) {
            ClockFixture(mounts: mounts, log: log, timeSource: timeSource)
        }
    }

    @Observable final class Mounts {
        var showsLate = false
        var revision = 0
    }

    private final class PhaseLog {
        var phases: [String: Bool] = [:]
        var changes: [String: Int] = [:]
    }

    /// Manual `Clock` used only by this test. `sleep(until:)` suspends the caller until a matching
    /// `advance(by:)` call moves `now` at or past the deadline, then resumes the waiter. Only ever driven
    /// from this `@MainActor` test, so the unchecked `Sendable` conformance and lack of internal locking is
    /// safe in practice even though it is not statically enforced.
    private final class ManualHerdrHudMetadataClock: Clock, @unchecked Sendable {
        struct Instant: InstantProtocol {
            fileprivate var offset: Duration
            static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
        }

        private struct Waiter {
            let deadline: Instant
            let continuation: CheckedContinuation<Void, Never>
        }

        private(set) var now = Instant(offset: .zero)
        let minimumResolution: Duration = .zero
        private var waiters: [Waiter] = []

        func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
            guard deadline > now else { return }
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(deadline: deadline, continuation: continuation))
            }
        }

        func advance(by duration: Duration) {
            now = now.advanced(by: duration)
            let ready = waiters.filter { $0.deadline <= now }
            waiters.removeAll { $0.deadline <= now }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }
    }

    private struct ClockFixture: View {
        let mounts: Mounts
        let log: PhaseLog
        let timeSource: HerdrHudMetadataTimeSource

        var body: some View {
            VStack {
                PhaseProbe(id: "first", log: log)
                if mounts.showsLate {
                    PhaseProbe(id: "late", log: log).id(mounts.revision)
                }
            }
            .modifier(HerdrHudSessionMetadataClock())
            .environment(\.herdrHudMetadataTimeSource, timeSource)
        }
    }

    private struct PhaseProbe: View {
        let id: String
        let log: PhaseLog
        @Environment(\.herdrHudShowsModel) private var showsModel

        var body: some View {
            HerdrHudSessionMetadataView(metadata: .init(modelName: "Sonnet 4.5", cost: "$0.37"))
                .onChange(of: showsModel, initial: true) { _, phase in
                    log.phases[id] = phase
                    log.changes[id, default: 0] += 1
                }
        }
    }
}
