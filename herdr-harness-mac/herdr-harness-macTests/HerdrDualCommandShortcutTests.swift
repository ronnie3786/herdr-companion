import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("Dual Command screenshot shortcut")
@MainActor
struct HerdrDualCommandShortcutTests {
    @Test("Quartz adapter queries combined-session left and right Command independently")
    func quartzAdapterQueriesBothCommandKeys() {
        var queries: [(CGEventSourceStateID, CGKeyCode)] = []

        let state = HerdrDualCommandShortcut.state { sourceState, keyCode in
            queries.append((sourceState, keyCode))
            return keyCode == HerdrDualCommandShortcut.rightCommandKeyCode
        }

        #expect(HerdrDualCommandShortcut.leftCommandKeyCode == CGKeyCode(kVK_Command))
        #expect(HerdrDualCommandShortcut.leftCommandKeyCode == 55)
        #expect(HerdrDualCommandShortcut.rightCommandKeyCode == CGKeyCode(kVK_RightCommand))
        #expect(HerdrDualCommandShortcut.rightCommandKeyCode == 54)
        #expect(queries.count == 2)
        #expect(queries[0].0 == .combinedSessionState)
        #expect(queries[0].1 == 55)
        #expect(queries[1].0 == .combinedSessionState)
        #expect(queries[1].1 == 54)
        #expect(!state.isLeftCommandPressed)
        #expect(state.isRightCommandPressed)
    }

    @Test("Neither or either Command alone does not fire")
    func incompleteCommandStatesDoNotFire() {
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut { invocations += 1 }

        shortcut.sample(state: state(left: false, right: false))
        shortcut.sample(state: state(left: true, right: false))
        shortcut.sample(state: state(left: false, right: true))

        #expect(invocations == 0)
    }

    @Test("Both Commands fire once while held, then rearm after either releases")
    func chordFiresOncePerPhysicalPress() {
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut { invocations += 1 }

        shortcut.sample(state: state(left: true, right: true))
        shortcut.sample(state: state(left: true, right: true))
        shortcut.sample(state: state(left: true, right: false))
        shortcut.sample(state: state(left: true, right: true))

        #expect(invocations == 2)
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
            handler: { invocations += 1 }
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

    private func state(left: Bool, right: Bool) -> HerdrDualCommandShortcut.State {
        HerdrDualCommandShortcut.State(
            isLeftCommandPressed: left,
            isRightCommandPressed: right
        )
    }
}
