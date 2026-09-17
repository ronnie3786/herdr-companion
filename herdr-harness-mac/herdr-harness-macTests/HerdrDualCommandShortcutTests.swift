import Testing
@testable import herdr_harness_mac

@Suite("Dual Command screenshot shortcut")
@MainActor
struct HerdrDualCommandShortcutTests {
    @Test("Left and right Command independently do not fire")
    func individualCommandKeysDoNotFire() {
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut { invocations += 1 }

        shortcut.sample(flags: HerdrDualCommandShortcut.leftCommandMask)
        shortcut.sample(flags: 0)
        shortcut.sample(flags: HerdrDualCommandShortcut.rightCommandMask)

        #expect(invocations == 0)
    }

    @Test("The chord fires once until either key releases, then can fire again")
    func chordFiresOncePerPhysicalPress() {
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut { invocations += 1 }
        let chord = HerdrDualCommandShortcut.leftCommandMask
            | HerdrDualCommandShortcut.rightCommandMask

        shortcut.sample(flags: chord)
        shortcut.sample(flags: chord)
        shortcut.sample(flags: HerdrDualCommandShortcut.leftCommandMask)
        shortcut.sample(flags: chord)

        #expect(invocations == 2)
    }

    @Test("Unrelated modifier bits do not change chord detection")
    func ignoresUnrelatedModifiers() {
        var invocations = 0
        let shortcut = HerdrDualCommandShortcut { invocations += 1 }
        let shiftMask: UInt = 0x0000_0002

        shortcut.sample(flags: shiftMask | HerdrDualCommandShortcut.leftCommandMask)
        shortcut.sample(flags: shiftMask | HerdrDualCommandShortcut.leftCommandMask
                        | HerdrDualCommandShortcut.rightCommandMask)

        #expect(invocations == 1)
    }

    @Test("Registering while held does not refire, and unregister rejects callbacks from the old registration")
    func unregisterInvalidatesQueuedSampling() {
        var flagsReads = 0
        var invocations = 0
        let chord = HerdrDualCommandShortcut.leftCommandMask
            | HerdrDualCommandShortcut.rightCommandMask
        let shortcut = HerdrDualCommandShortcut(
            flagsProvider: {
                flagsReads += 1
                return chord
            },
            handler: { invocations += 1 }
        )

        #expect(shortcut.register())
        let oldGeneration = shortcut.registrationGeneration
        #expect(invocations == 0)
        shortcut.unregister()
        shortcut.sampleCurrentFlags(ifRegistrationGeneration: oldGeneration)

        #expect(flagsReads == 1)
        #expect(invocations == 0)
        shortcut.sample(flags: chord)
        #expect(invocations == 1)
    }
}
