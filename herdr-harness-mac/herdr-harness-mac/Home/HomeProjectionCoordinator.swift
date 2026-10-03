import Foundation
import Observation

/// Coalesces authoritative observations outside view evaluation. It performs no
/// networking and changes no selection or read markers in those stores.
@MainActor @Observable
final class HomeProjectionCoordinator {
    private var now = Date.now
    @ObservationIgnored private(set) var projectionCount = 0

    private struct Capture: Sendable {
        let input: HomeInput
        let now: Date
    }

    func run(model: HerdrAppModel, shell: HerdrShellState, home: HomeStore) async {
        now = .now
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.advanceClock() }
            let observations = Observations {
                Capture(input: HomeInputAdapter.make(model: model, shell: shell, previousVisit: home.previousVisit), now: self.now)
            }
            for await capture in observations {
                guard !Task.isCancelled else { break }
                let projected = HomeProjection.project(capture.input, now: capture.now, calendar: .current)
                projectionCount += 1
                home.receive(projected, now: capture.now)
                // Observations yields the latest transaction when iteration
                // resumes, coalescing bursts rather than queueing every frame.
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
            group.cancelAll()
        }
    }

    private func advanceClock() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            now = .now
        }
    }
}
