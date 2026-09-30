import AppKit
import Carbon.HIToolbox
import Testing
@testable import herdr_harness_mac

@Suite("Simulator key map")
struct SimulatorKeyMapTests {
    private func code(_ key: Int) -> UInt16 { UInt16(key) }

    /// AppKit's flags for a modifier key: the device-independent flag plus its side's device bit.
    private func flags(_ flag: NSEvent.ModifierFlags, device: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: flag.rawValue | device)
    }

    @Test("Virtual key codes map to USB HID usages")
    func usages() {
        let expected: [(Int, Int)] = [
            (kVK_ANSI_A, 0x04), (kVK_ANSI_B, 0x05), (kVK_ANSI_M, 0x10), (kVK_ANSI_Z, 0x1D),
            (kVK_ANSI_1, 0x1E), (kVK_ANSI_9, 0x26), (kVK_ANSI_0, 0x27),
            (kVK_Return, 0x28), (kVK_Escape, 0x29), (kVK_Delete, 0x2A), (kVK_Tab, 0x2B), (kVK_Space, 0x2C),
            (kVK_ANSI_Minus, 0x2D), (kVK_ANSI_Equal, 0x2E), (kVK_ANSI_LeftBracket, 0x2F), (kVK_ANSI_RightBracket, 0x30),
            (kVK_ANSI_Backslash, 0x31), (kVK_ANSI_Semicolon, 0x33), (kVK_ANSI_Quote, 0x34), (kVK_ANSI_Grave, 0x35),
            (kVK_ANSI_Comma, 0x36), (kVK_ANSI_Period, 0x37), (kVK_ANSI_Slash, 0x38), (kVK_CapsLock, 0x39),
            (kVK_F1, 0x3A), (kVK_F5, 0x3E), (kVK_F12, 0x45),
            (kVK_Home, 0x4A), (kVK_PageUp, 0x4B), (kVK_ForwardDelete, 0x4C), (kVK_End, 0x4D), (kVK_PageDown, 0x4E),
            (kVK_RightArrow, 0x4F), (kVK_LeftArrow, 0x50), (kVK_DownArrow, 0x51), (kVK_UpArrow, 0x52),
            (kVK_ANSI_Keypad1, 0x59), (kVK_ANSI_Keypad9, 0x61), (kVK_ANSI_Keypad0, 0x62), (kVK_ANSI_KeypadEnter, 0x58),
            (kVK_Control, 0xE0), (kVK_Shift, 0xE1), (kVK_Option, 0xE2), (kVK_Command, 0xE3),
            (kVK_RightControl, 0xE4), (kVK_RightShift, 0xE5), (kVK_RightOption, 0xE6), (kVK_RightCommand, 0xE7),
        ]
        for (keyCode, usage) in expected {
            #expect(SimulatorKeyMap.usage(forKeyCode: code(keyCode)) == usage, "kVK \(keyCode)")
        }
        #expect(SimulatorKeyMap.usage(forKeyCode: code(kVK_Function)) == nil)
    }

    @Test("Letters cover a through z once each")
    func letters() {
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
                       kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
                       kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                       kVK_ANSI_Y, kVK_ANSI_Z]
        #expect(letters.compactMap { SimulatorKeyMap.usage(forKeyCode: code($0)) } == Array(0x04...0x1D))
    }

    @Test("Plain keys go down once, ignore repeats, and come up once")
    func plainKeys() {
        var keyboard = SimulatorKeyboardState()
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_A), modifiers: [], isRepeat: false) == .forward([.key(usage: 0x04, phase: .down)]))
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_A), modifiers: [], isRepeat: true) == .forward([]))
        #expect(keyboard.held == [0x04])
        #expect(keyboard.keyUp(keyCode: code(kVK_ANSI_A)) == [.key(usage: 0x04, phase: .up)])
        #expect(keyboard.keyUp(keyCode: code(kVK_ANSI_A)).isEmpty)
        #expect(keyboard.held.isEmpty)
        // Option is not a shortcut: ⌥A types into the simulator.
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_A), modifiers: .option, isRepeat: false) == .forward([.key(usage: 0x04, phase: .down)]))
    }

    @Test("Modifier keys go down and up by side")
    func modifiers() {
        var keyboard = SimulatorKeyboardState()
        let leftShift = flags(.shift, device: 0x02)
        let bothShifts = flags(.shift, device: 0x02 | 0x04)
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Shift), modifiers: leftShift) == [.key(usage: 0xE1, phase: .down)])
        #expect(keyboard.flagsChanged(keyCode: code(kVK_RightShift), modifiers: bothShifts) == [.key(usage: 0xE5, phase: .down)])
        // Right Shift lifts while Left Shift still holds the shared flag.
        #expect(keyboard.flagsChanged(keyCode: code(kVK_RightShift), modifiers: leftShift) == [.key(usage: 0xE5, phase: .up)])
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Shift), modifiers: []) == [.key(usage: 0xE1, phase: .up)])
        #expect(keyboard.held.isEmpty)

        // Synthetic events without device bits fall back to the shared flag.
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Command), modifiers: .command) == [.key(usage: 0xE3, phase: .down)])
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Command), modifiers: .command).isEmpty)
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Command), modifiers: []) == [.key(usage: 0xE3, phase: .up)])

        #expect(keyboard.flagsChanged(keyCode: code(kVK_RightOption), modifiers: flags(.option, device: 0x40)) == [.key(usage: 0xE6, phase: .down)])
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Control), modifiers: flags([.option, .control], device: 0x40 | 0x01))
                == [.key(usage: 0xE0, phase: .down)])
        #expect(keyboard.held == [0xE6, 0xE0])

        // Caps Lock toggles with each report, so it is a whole press.
        #expect(keyboard.flagsChanged(keyCode: code(kVK_CapsLock), modifiers: .capsLock) == [.key(usage: 0x39, phase: .press)])
        #expect(keyboard.flagsChanged(keyCode: code(kVK_CapsLock), modifiers: []) == [.key(usage: 0x39, phase: .press)])
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Function), modifiers: .function).isEmpty)
    }

    @Test("While ⌘ is held, keys are sent as whole presses")
    func commandPresses() {
        var keyboard = SimulatorKeyboardState()
        let command = flags(.command, device: 0x08)
        #expect(keyboard.flagsChanged(keyCode: code(kVK_Command), modifiers: command) == [.key(usage: 0xE3, phase: .down)])
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_B), modifiers: command, isRepeat: false) == .forward([.key(usage: 0x05, phase: .press)]))
        #expect(keyboard.keyDown(keyCode: code(kVK_LeftArrow), modifiers: command, isRepeat: false) == .forward([.key(usage: 0x50, phase: .press)]))
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_A), modifiers: command, isRepeat: false) == .forward([.key(usage: 0x04, phase: .press)]))
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_B), modifiers: command, isRepeat: true) == .forward([]))
        // Nothing but ⌘ is held, since AppKit never delivers those key-ups.
        #expect(keyboard.held == [0xE3])
    }

    @Test("⌘-shortcuts: simulator buttons, paste and editing are claimed; app shortcuts are not")
    func keyEquivalents() {
        let command = flags(.command, device: 0x08)
        let commandShift = flags([.command, .shift], device: 0x08 | 0x02)
        let classify = { (key: Int, modifiers: NSEvent.ModifierFlags) in
            SimulatorKeyboardState.keyEquivalent(keyCode: UInt16(key), modifiers: modifiers)
        }
        #expect(classify(kVK_ANSI_H, commandShift) == .button(.home))
        #expect(classify(kVK_ANSI_L, command) == .button(.lock))
        #expect(classify(kVK_ANSI_V, command) == .paste)
        for key in [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_Z] {
            #expect(classify(key, command) == .forward)
        }
        #expect(classify(kVK_ANSI_Z, commandShift) == .forward)
        for key in [kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_M, kVK_ANSI_H, kVK_ANSI_Grave, kVK_ANSI_Comma, kVK_Tab, kVK_ANSI_N, kVK_ANSI_T] {
            #expect(classify(key, command) == .appShortcut, "⌘ kVK \(key)")
        }
        // Extra modifiers make a different shortcut.
        #expect(classify(kVK_ANSI_V, flags([.command, .option], device: 0x08 | 0x20)) == .appShortcut)
        #expect(classify(kVK_ANSI_L, flags([.command, .control], device: 0x08 | 0x01)) == .appShortcut)
        #expect(classify(kVK_ANSI_V, []) == .appShortcut)

        var keyboard = SimulatorKeyboardState()
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_H), modifiers: commandShift, isRepeat: false) == .button(.home))
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_H), modifiers: commandShift, isRepeat: true) == .forward([]))
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_L), modifiers: command, isRepeat: false) == .button(.lock))
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_V), modifiers: command, isRepeat: false) == .paste)
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_C), modifiers: command, isRepeat: false) == .forward([.key(usage: 0x06, phase: .press)]))
        for key in [kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_M, kVK_ANSI_H, kVK_ANSI_Grave, kVK_ANSI_Comma, kVK_Tab] {
            #expect(keyboard.keyDown(keyCode: code(key), modifiers: command, isRepeat: false) == .passThrough, "⌘ kVK \(key)")
        }
        #expect(keyboard.held.isEmpty)
    }

    @Test("Releasing everything lifts held keys, most recent first")
    func releaseAll() {
        var keyboard = SimulatorKeyboardState()
        _ = keyboard.flagsChanged(keyCode: code(kVK_Shift), modifiers: flags(.shift, device: 0x02))
        _ = keyboard.keyDown(keyCode: code(kVK_ANSI_K), modifiers: flags(.shift, device: 0x02), isRepeat: false)
        _ = keyboard.keyDown(keyCode: code(kVK_Space), modifiers: flags(.shift, device: 0x02), isRepeat: false)
        #expect(keyboard.releaseAll() == [
            .key(usage: 0x2C, phase: .up), .key(usage: 0x0E, phase: .up), .key(usage: 0xE1, phase: .up),
        ])
        #expect(keyboard.releaseAll().isEmpty)
        // After a release, the same key goes down again.
        #expect(keyboard.keyDown(keyCode: code(kVK_ANSI_K), modifiers: [], isRepeat: false) == .forward([.key(usage: 0x0E, phase: .down)]))
    }
}
