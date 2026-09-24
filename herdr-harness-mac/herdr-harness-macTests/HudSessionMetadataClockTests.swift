import Foundation
import Observation
import SwiftUI
import Testing
import Vision
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

    @Test("HUD chat and ordinary agent content join the same five-second phase")
    func chatAndAgentSharePhase() async throws {
        let log = PhaseLog()
        let clock = ManualHerdrHudMetadataClock()
        let timeSource = HerdrHudMetadataTimeSource(clock)
        let suiteName = "HudSessionMetadataClockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let chatSession = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(suiteName)-hud-thread.json")
        )
        let metadata = HerdrHudSessionMetadata(modelName: "Sonnet 4.5", cost: "$0.37")
        let agentChip = HerdrHudSessionChips.Chip(
            id: "synthetic|w1:p1",
            title: "Synthetic agent",
            status: .working,
            isMuted: false,
            since: nil,
            emoji: "",
            activity: "Running tests"
        )

        func settle(maxAttempts: Int = 200, until condition: () -> Bool) async {
            for _ in 0..<maxAttempts {
                if condition() { return }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        let render = try await HerdrRenderHarness.render(
            "hud-shared-clock-surfaces.png",
            size: CGSize(width: 240, height: 220),
            afterSettling: {
                await settle { log.phases["chat"] != nil && log.phases["agent"] != nil }
                #expect(log.phases["chat"] == log.phases["agent"])

                // One-second chunks cross at most one boundary each, giving
                // SwiftUI a real chance to flush the recomputed environment
                // through both surfaces between virtual instants.
                for _ in 0..<6 {
                    clock.advance(by: .milliseconds(1_000))
                    let expected = HerdrHudSessionMetadataCycle.showsModel(at: timeSource.now())
                    await settle { log.phases["chat"] == expected && log.phases["agent"] == expected }
                }
                #expect((log.changes["chat"] ?? 0) >= 2)
                #expect((log.changes["agent"] ?? 0) >= 2)
                #expect(log.phases["chat"] == log.phases["agent"])
                // Let the last phase's 0.3-second fade finish before the
                // harness snapshots, so OCR cannot catch both labels.
                try? await Task.sleep(for: .milliseconds(450))
                await settle { log.phases["chat"] == HerdrHudSessionMetadataCycle.showsModel(at: timeSource.now()) }
            }
        ) {
            VStack(spacing: 8) {
                ContentPhaseProbe(id: "chat", log: log) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        HerdrHudChatStatusView(session: chatSession)
                        HerdrHudSessionMetadataView(metadata: metadata)
                    }
                }
                ContentPhaseProbe(id: "agent", log: log) {
                    HerdrHudSessionBubbleLabel(chip: agentChip, metadata: metadata)
                }
            }
            .modifier(HerdrHudSessionMetadataClock())
            .environment(\.herdrHudMetadataTimeSource, timeSource)
        }
        render.expectSubstantial(minimumBytes: 2_000)

        // The snapshot is taken after the fixture settles, so both surfaces
        // must show only the phase the shared clock holds right now.
        let showsModel = HerdrHudSessionMetadataCycle.showsModel(at: timeSource.now())
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.005
        try HerdrOCR.perform(request, url: render.url)
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        if showsModel {
            #expect(visible.contains("Sonnet 4.5"))
            #expect(!visible.contains("$0.37"))
        } else {
            #expect(visible.contains("$0.37"))
            #expect(!visible.contains("Sonnet 4.5"))
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

    /// Logs the shared phase as the supplied HUD chat or agent content sees it.
    private struct ContentPhaseProbe<Content: View>: View {
        let id: String
        let log: PhaseLog
        @ViewBuilder var content: () -> Content
        @Environment(\.herdrHudShowsModel) private var showsModel

        var body: some View {
            content()
                .onChange(of: showsModel, initial: true) { _, phase in
                    log.phases[id] = phase
                    log.changes[id, default: 0] += 1
                }
        }
    }
}
