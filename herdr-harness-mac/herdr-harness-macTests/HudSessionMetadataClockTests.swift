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
        _ = try await HerdrRenderHarness.render("hud-shared-clock-test.png", size: CGSize(width: 240, height: 90), afterSettling: {
            #expect(log.phases["first"] != nil)
            try await Task.sleep(for: .milliseconds(1250))
            mounts.showsLate = true
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.phases["late"] == log.phases["first"])
            try await Task.sleep(for: .milliseconds(5250))
            #expect((log.changes["first"] ?? 0) >= 2)
            #expect((log.changes["late"] ?? 0) >= 2)
            #expect(log.phases["late"] == log.phases["first"])
            mounts.revision += 1
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.phases["late"] == log.phases["first"])
        }) {
            ClockFixture(mounts: mounts, log: log)
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

    private struct ClockFixture: View {
        let mounts: Mounts
        let log: PhaseLog

        var body: some View {
            VStack {
                PhaseProbe(id: "first", log: log)
                if mounts.showsLate {
                    PhaseProbe(id: "late", log: log).id(mounts.revision)
                }
            }
            .modifier(HerdrHudSessionMetadataClock())
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
