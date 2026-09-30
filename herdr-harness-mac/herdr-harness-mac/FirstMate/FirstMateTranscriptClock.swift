import AppKit
import Observation
import SwiftUI

/// One observer owner per mounted transcript, never one timer/observer per bubble.
@MainActor @Observable
final class FirstMateTranscriptClock {
    private(set) var now: Date
    @ObservationIgnored private let readNow: () -> Date
    @ObservationIgnored private let observations: Observations

    init(now: @escaping () -> Date = { .now }, center: NotificationCenter = .default) {
        readNow = now
        self.now = now()
        observations = Observations(center: center)
    }

    var observationCount: Int { observations.tokens.count }

    func start() {
        now = readNow()
        guard observations.tokens.isEmpty else { return }
        for name in [Notification.Name.NSCalendarDayChanged, NSApplication.didBecomeActiveNotification] {
            observations.tokens.append(observations.center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() { now = readNow() }
    func stop() { observations.remove() }

    /// Also cleans up if the state owner is destroyed without onDisappear.
    private final class Observations {
        let center: NotificationCenter
        var tokens: [NSObjectProtocol] = []
        init(center: NotificationCenter) { self.center = center }
        func remove() {
            tokens.forEach(center.removeObserver)
            tokens.removeAll()
        }
        deinit { remove() }
    }
}

private struct FirstMateTranscriptNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    var firstMateTranscriptNow: Date? {
        get { self[FirstMateTranscriptNowKey.self] }
        set { self[FirstMateTranscriptNowKey.self] = newValue }
    }
}

struct FirstMateTranscriptClockLifecycle: ViewModifier {
    let clock: FirstMateTranscriptClock

    func body(content: Content) -> some View {
        content
            .environment(\.firstMateTranscriptNow, clock.now)
            .onAppear { clock.start() }
            .onDisappear { clock.stop() }
    }
}
