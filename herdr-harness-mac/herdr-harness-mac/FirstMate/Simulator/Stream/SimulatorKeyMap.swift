import AppKit
import Carbon.HIToolbox

/// macOS virtual key codes (`kVK_*`) to USB HID keyboard usages (page 0x07),
/// the numbers SimPortal hands to the simulator. Key codes name physical
/// positions, so the simulator's own hardware-keyboard layout decides which
/// character a key produces, exactly as with SimPortal's browser viewer.
enum SimulatorKeyMap {
    static let capsLockUsage = 0x39

    static func usage(forKeyCode keyCode: UInt16) -> Int? {
        usages[keyCode]
    }

    static func isModifier(usage: Int) -> Bool {
        (0xE0...0xE7).contains(usage) || usage == capsLockUsage
    }

    /// A modifier key's usage, the device-independent flag it sets, and its
    /// side's device-dependent bit (`NX_DEVICE*KEYMASK` in IOLLEvent.h).
    struct Modifier: Equatable, Sendable {
        let usage: Int
        let flag: NSEvent.ModifierFlags
        let deviceMask: UInt
    }

    static func modifier(forKeyCode keyCode: UInt16) -> Modifier? {
        modifiers[keyCode]
    }

    /// Every side-specific modifier bit AppKit leaves in `modifierFlags.rawValue`.
    static let deviceModifierMask: UInt = 0x207F

    private static let modifiers: [UInt16: Modifier] = [
        UInt16(kVK_Control): Modifier(usage: 0xE0, flag: .control, deviceMask: 0x0001),
        UInt16(kVK_Shift): Modifier(usage: 0xE1, flag: .shift, deviceMask: 0x0002),
        UInt16(kVK_Option): Modifier(usage: 0xE2, flag: .option, deviceMask: 0x0020),
        UInt16(kVK_Command): Modifier(usage: 0xE3, flag: .command, deviceMask: 0x0008),
        UInt16(kVK_RightControl): Modifier(usage: 0xE4, flag: .control, deviceMask: 0x2000),
        UInt16(kVK_RightShift): Modifier(usage: 0xE5, flag: .shift, deviceMask: 0x0004),
        UInt16(kVK_RightOption): Modifier(usage: 0xE6, flag: .option, deviceMask: 0x0040),
        UInt16(kVK_RightCommand): Modifier(usage: 0xE7, flag: .command, deviceMask: 0x0010),
    ]

    private static let usages: [UInt16: Int] = {
        let letters = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
            kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
            kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
            kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ]
        let digits = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        let laterFunctionKeys = [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let keypadDigits = [
            kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
            kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_Keypad0,
        ]
        var table: [Int: Int] = [
            kVK_Return: 0x28, kVK_Escape: 0x29, kVK_Delete: 0x2A, kVK_Tab: 0x2B, kVK_Space: 0x2C,
            kVK_ANSI_Minus: 0x2D, kVK_ANSI_Equal: 0x2E, kVK_ANSI_LeftBracket: 0x2F, kVK_ANSI_RightBracket: 0x30,
            kVK_ANSI_Backslash: 0x31, kVK_ANSI_Semicolon: 0x33, kVK_ANSI_Quote: 0x34, kVK_ANSI_Grave: 0x35,
            kVK_ANSI_Comma: 0x36, kVK_ANSI_Period: 0x37, kVK_ANSI_Slash: 0x38, kVK_CapsLock: capsLockUsage,
            kVK_Help: 0x49, kVK_Home: 0x4A, kVK_PageUp: 0x4B, kVK_ForwardDelete: 0x4C, kVK_End: 0x4D,
            kVK_PageDown: 0x4E, kVK_RightArrow: 0x4F, kVK_LeftArrow: 0x50, kVK_DownArrow: 0x51, kVK_UpArrow: 0x52,
            kVK_ANSI_KeypadClear: 0x53, kVK_ANSI_KeypadDivide: 0x54, kVK_ANSI_KeypadMultiply: 0x55,
            kVK_ANSI_KeypadMinus: 0x56, kVK_ANSI_KeypadPlus: 0x57, kVK_ANSI_KeypadEnter: 0x58,
            kVK_ANSI_KeypadDecimal: 0x63, kVK_ISO_Section: 0x64, kVK_ANSI_KeypadEquals: 0x67,
            kVK_JIS_Underscore: 0x87, kVK_JIS_Yen: 0x89, kVK_JIS_Kana: 0x90, kVK_JIS_Eisu: 0x91,
            kVK_JIS_KeypadComma: 0x85,
        ]
        for (offset, key) in letters.enumerated() { table[key] = 0x04 + offset }
        for (offset, key) in digits.enumerated() { table[key] = 0x1E + offset }
        for (offset, key) in functionKeys.enumerated() { table[key] = 0x3A + offset }
        for (offset, key) in laterFunctionKeys.enumerated() { table[key] = 0x68 + offset }
        for (offset, key) in keypadDigits.enumerated() { table[key] = 0x59 + offset }
        for (keyCode, modifier) in modifiers { table[Int(keyCode)] = modifier.usage }
        return Dictionary(uniqueKeysWithValues: table.map { (UInt16($0.key), $0.value) })
    }()
}

/// A ⌘-shortcut seen by the screen view before the app's menus.
enum SimulatorKeyEquivalent: Equatable, Sendable {
    case button(SimulatorHardwareButton)
    /// ⌘V: the Mac's clipboard goes to the simulator's pasteboard.
    case paste
    /// An editing combo (⌘A ⌘C ⌘X ⌘Z ⌘⇧Z) the simulator gets instead of the Edit menu.
    case forward
    /// Not the simulator's: window and app shortcuts keep working.
    case appShortcut
}

/// What the screen view does with a key-down that reached it.
enum SimulatorKeyCommand: Equatable, Sendable {
    /// Send these (possibly none, e.g. for a repeat the simulator makes itself).
    case forward([SimulatorClientMessage])
    case button(SimulatorHardwareButton)
    case paste
    /// Hand it back to AppKit.
    case passThrough
}

/// Which keys the simulator currently holds down, so every "down" is paired
/// with an "up" even when focus or the connection goes away mid-press.
struct SimulatorKeyboardState: Equatable, Sendable {
    private(set) var held: [Int] = []

    /// ⌘-letters that stay the app's even while typing goes to the simulator.
    private static let appKeys: Set<Int> = [kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_M, kVK_ANSI_H, kVK_ANSI_Grave, kVK_ANSI_Comma, kVK_Tab]
    private static let editingKeys: Set<Int> = [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_Z]

    static func keyEquivalent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> SimulatorKeyEquivalent {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        let key = Int(keyCode)
        switch flags {
        case [.command, .shift] where key == kVK_ANSI_H: return .button(.home)
        case [.command, .shift] where key == kVK_ANSI_Z: return .forward
        case [.command] where key == kVK_ANSI_L: return .button(.lock)
        case [.command] where key == kVK_ANSI_V: return .paste
        case [.command] where editingKeys.contains(key): return .forward
        default: return .appShortcut
        }
    }

    mutating func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> SimulatorKeyCommand {
        let command = modifiers.contains(.command)
        if command {
            switch Self.keyEquivalent(keyCode: keyCode, modifiers: modifiers) {
            case .button(let button): return isRepeat ? .forward([]) : .button(button)
            case .paste: return isRepeat ? .forward([]) : .paste
            case .forward: break
            case .appShortcut: if Self.appKeys.contains(Int(keyCode)) { return .passThrough }
            }
        }
        // Unmapped keys are swallowed rather than beeping.
        guard let usage = SimulatorKeyMap.usage(forKeyCode: keyCode) else { return .forward([]) }
        // iOS repeats a held key itself.
        if isRepeat || held.contains(usage) { return .forward([]) }
        if command && !SimulatorKeyMap.isModifier(usage: usage) {
            // AppKit never delivers the key-up of a ⌘ combo, so send the whole press now.
            return .forward([.key(usage: usage, phase: .press)])
        }
        held.append(usage)
        return .forward([.key(usage: usage, phase: .down)])
    }

    mutating func keyUp(keyCode: UInt16) -> [SimulatorClientMessage] {
        guard let usage = SimulatorKeyMap.usage(forKeyCode: keyCode), let index = held.firstIndex(of: usage) else { return [] }
        held.remove(at: index)
        return [.key(usage: usage, phase: .up)]
    }

    mutating func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [SimulatorClientMessage] {
        // Caps Lock reports each toggle once, with no release to pair.
        if Int(keyCode) == kVK_CapsLock { return [.key(usage: SimulatorKeyMap.capsLockUsage, phase: .press)] }
        guard let modifier = SimulatorKeyMap.modifier(forKeyCode: keyCode) else { return [] }
        let isDown = Self.isPressed(modifier, in: modifiers)
        if isDown, !held.contains(modifier.usage) {
            held.append(modifier.usage)
            return [.key(usage: modifier.usage, phase: .down)]
        }
        if !isDown, let index = held.firstIndex(of: modifier.usage) {
            held.remove(at: index)
            return [.key(usage: modifier.usage, phase: .up)]
        }
        return []
    }

    /// Lifts everything still held, most recent first.
    mutating func releaseAll() -> [SimulatorClientMessage] {
        let messages = held.reversed().map { SimulatorClientMessage.key(usage: $0, phase: .up) }
        held.removeAll()
        return messages
    }

    /// Tells the two sides of a modifier apart with the device-dependent bits,
    /// so releasing one Shift while the other is held reads as a release.
    static func isPressed(_ modifier: SimulatorKeyMap.Modifier, in modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(modifier.flag) else { return false }
        let deviceBits = modifiers.rawValue & SimulatorKeyMap.deviceModifierMask
        // Synthetic events can carry only the device-independent flag.
        guard deviceBits != 0 else { return true }
        return deviceBits & modifier.deviceMask != 0
    }
}
