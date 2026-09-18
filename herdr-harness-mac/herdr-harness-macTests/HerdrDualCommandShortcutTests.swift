import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("Dual Command screenshot shortcut")
@MainActor
struct HerdrDualCommandShortcutTests {
    @Test("Neither or either Command alone does not fire")
    func incompleteCommandStatesDoNotFire() {
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut(stateProvider: idling) { _ in invocations += 1 }

        shortcut.sample(state: state(left: false, right: false))
        shortcut.sample(state: state(left: true, right: false))
        shortcut.sample(state: state(left: false, right: true))

        #expect(invocations == 0)
    }

    @Test("Both Commands fire once while held, then rearm after either releases")
    func chordFiresOncePerPhysicalPress() {
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut(stateProvider: idling) { _ in invocations += 1 }

        shortcut.sample(state: state(left: true, right: true))
        shortcut.sample(state: state(left: true, right: true))
        shortcut.sample(state: state(left: true, right: false))
        shortcut.sample(state: state(left: true, right: true))

        #expect(invocations == 2)
    }

    @Test("The observing signal is reported with the trigger")
    func triggerReportsSignal() {
        var signals: [HerdrCommandKeySignal] = []
        let shortcut = HerdrDualCommandShortcut(stateProvider: idling) { signals.append($0) }

        shortcut.sample(state: HerdrCommandKeyState(
            isLeftCommandPressed: true,
            isRightCommandPressed: true,
            signal: .flagsState
        ))
        shortcut.sample(state: state(left: false, right: false))
        shortcut.sample(state: HerdrCommandKeyState(
            isLeftCommandPressed: true,
            isRightCommandPressed: true,
            signal: .globalMonitor
        ))

        #expect(signals == [.flagsState, .globalMonitor])
    }

    @Test("Registering while held does not fire and stale registrations stay inert after re-register")
    func registrationPrimingAndGenerationIsolation() {
        var currentState = state(left: true, right: true)
        var stateReads = 0
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut(
            stateProvider: {
                stateReads += 1
                return currentState
            },
            handler: { _ in invocations += 1 }
        )
        defer { shortcut.unregister() }

        #expect(shortcut.register())
        let staleGeneration = shortcut.registrationGeneration
        #expect(stateReads == 1)
        #expect(invocations == 0)

        shortcut.unregister()
        currentState = state(left: false, right: false)
        #expect(shortcut.register())
        let currentGeneration = shortcut.registrationGeneration
        #expect(stateReads == 2)

        currentState = state(left: true, right: true)
        shortcut.sampleCurrentState(ifRegistrationGeneration: staleGeneration)
        #expect(stateReads == 2)
        #expect(invocations == 0)

        shortcut.sampleCurrentState(ifRegistrationGeneration: currentGeneration)
        #expect(stateReads == 3)
        #expect(invocations == 1)
    }

    private func idling() -> HerdrCommandKeyState {
        state(left: false, right: false)
    }

    private func state(left: Bool, right: Bool) -> HerdrCommandKeyState {
        HerdrCommandKeyState(
            isLeftCommandPressed: left,
            isRightCommandPressed: right,
            signal: left || right ? .keyState : .unavailable
        )
    }
}

@Suite("Command key monitor")
@MainActor
struct HerdrCommandKeyMonitorTests {
    @Test("Both Command key codes are queried independently, in the combined session")
    func queriesBothCommandKeys() {
        var queries: [(CGEventSourceStateID, CGKeyCode)] = []
        let monitor = makeMonitor { state, keyCode in
            queries.append((state, keyCode))
            // Only the right key reports a press; the left read must not be skipped.
            return keyCode == HerdrCommandKeyMonitor.rightCommandKeyCode
        }

        let state = monitor.currentState()

        #expect(HerdrCommandKeyMonitor.leftCommandKeyCode == CGKeyCode(kVK_Command))
        #expect(HerdrCommandKeyMonitor.leftCommandKeyCode == 55)
        #expect(HerdrCommandKeyMonitor.rightCommandKeyCode == CGKeyCode(kVK_RightCommand))
        #expect(HerdrCommandKeyMonitor.rightCommandKeyCode == 54)
        #expect(queries.count == 2)
        #expect(queries[0].0 == .combinedSessionState)
        #expect(queries[0].1 == 55)
        #expect(queries[1].0 == .combinedSessionState)
        #expect(queries[1].1 == 54)
        #expect(!state.isLeftCommandPressed)
        #expect(state.isRightCommandPressed)
        #expect(state.signal == .keyState)
    }

    @Test("Device-dependent modifier bits identify each Command key")
    func decodesDeviceBits() {
        let both = makeMonitor(keyState: { _, _ in false }, flags: { _ in
            HerdrCommandKeyMonitor.leftCommandDeviceMask | HerdrCommandKeyMonitor.rightCommandDeviceMask
        }).currentState()
        #expect(both.isLeftCommandPressed)
        #expect(both.isRightCommandPressed)
        #expect(both.signal == .flagsState)

        let leftOnly = makeMonitor(keyState: { _, _ in false }, flags: { _ in
            HerdrCommandKeyMonitor.leftCommandDeviceMask
        }).currentState()
        #expect(leftOnly.isLeftCommandPressed)
        #expect(!leftOnly.isRightCommandPressed)

        let rightOnly = makeMonitor(keyState: { _, _ in false }, flags: { _ in
            HerdrCommandKeyMonitor.rightCommandDeviceMask
        }).currentState()
        #expect(!rightOnly.isLeftCommandPressed)
        #expect(rightOnly.isRightCommandPressed)

        let neither = makeMonitor(keyState: { _, _ in false }, flags: { _ in 0 }).currentState()
        #expect(!neither.isLeftCommandPressed)
        #expect(!neither.isRightCommandPressed)
        #expect(neither.signal == .unavailable)
    }

    @Test("Either permission-free signal alone can prove a press")
    func unionsBothPollingSignals() {
        let fromKeyState = makeMonitor(keyState: { _, keyCode in keyCode == 55 }, flags: { _ in 0 }).currentState()
        #expect(fromKeyState.isLeftCommandPressed)
        #expect(fromKeyState.signal == .keyState)

        let fromFlags = makeMonitor(keyState: { _, _ in false }, flags: { _ in
            HerdrCommandKeyMonitor.rightCommandDeviceMask
        }).currentState()
        #expect(fromFlags.isRightCommandPressed)
        #expect(fromFlags.signal == .flagsState)
    }

    @Test("Monitoring never requests keyboard access, and stopping clears observed state")
    func accessIsNeverRequestedImplicitly() {
        var didRequest = false
        let monitor = makeMonitor(
            keyState: { _, _ in false },
            flags: { _ in 0 },
            listenEventAccess: { false },
            requestAccess: {
                didRequest = true
                return true
            }
        )

        monitor.startMonitoring()
        #expect(!didRequest)
        #expect(!monitor.isKeyboardAccessGranted)
        monitor.stopMonitoring()

        #expect(monitor.currentState().signal == .unavailable)
        #expect(monitor.requestKeyboardAccess())
        #expect(didRequest)
    }

    private func makeMonitor(
        keyState: @escaping HerdrCommandKeyMonitor.KeyStateQuery = { _, _ in false },
        flags: @escaping HerdrCommandKeyMonitor.FlagsQuery = { _ in 0 },
        listenEventAccess: @escaping HerdrCommandKeyMonitor.AccessQuery = { false },
        requestAccess: @escaping HerdrCommandKeyMonitor.AccessQuery = { false }
    ) -> HerdrCommandKeyMonitor {
        HerdrCommandKeyMonitor(
            keyStateQuery: keyState,
            flagsQuery: flags,
            listenEventAccess: listenEventAccess,
            requestListenEventAccess: requestAccess
        )
    }
}
