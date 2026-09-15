import Foundation
@preconcurrency import AppKit

struct HostDisplayModifierTransition {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}

enum HostDisplayInputEventKind: Equatable {
    case flagsChanged
    case keyDown
    case keyUp

    var nsEventType: NSEvent.EventType {
        switch self {
        case .flagsChanged: .flagsChanged
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        }
    }
}

struct HostDisplayInputEvent: Equatable {
    let kind: HostDisplayInputEventKind
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let characters: String
    let charactersIgnoringModifiers: String
}

struct HostDisplayKey {
    let keyCode: UInt16
    let characters: String
    let charactersIgnoringModifiers: String
    let modifiers: NSEvent.ModifierFlags

    /// The modifier-key sequence the view must forward to establish the same
    /// guest HID state as a physical chord. Press modifiers in a stable order,
    /// then release them in reverse order after the ordinary key-up event.
    var modifierPressTransitions: [HostDisplayModifierTransition] {
        var active: NSEvent.ModifierFlags = []
        var activeDeviceFlags: NSEvent.ModifierFlags = []
        return Self.physicalModifiers.compactMap { modifier in
            guard modifiers.contains(modifier.flag) else { return nil }
            active.insert(modifier.flag)
            activeDeviceFlags.insert(modifier.deviceFlag)
            return HostDisplayModifierTransition(
                keyCode: modifier.keyCode,
                modifiers: active.union(activeDeviceFlags)
            )
        }
    }

    var modifierReleaseTransitions: [HostDisplayModifierTransition] {
        var active = modifiers.intersection(Self.physicalModifierMask)
        var activeDeviceFlags = Self.deviceFlags(for: active)
        return Self.physicalModifiers.reversed().compactMap { modifier in
            guard active.contains(modifier.flag) else { return nil }
            active.remove(modifier.flag)
            activeDeviceFlags.remove(modifier.deviceFlag)
            return HostDisplayModifierTransition(
                keyCode: modifier.keyCode,
                modifiers: active.union(activeDeviceFlags)
            )
        }
    }

    /// The exact unposted AppKit events wrapped for direct VM delivery. Keeping
    /// this representation separate makes modifier ordering and character
    /// fields testable without constructing a Virtualization guest.
    var inputEventPlan: [HostDisplayInputEvent] {
        let presses = modifierPressTransitions.map {
            HostDisplayInputEvent(
                kind: .flagsChanged,
                keyCode: $0.keyCode,
                modifiers: $0.modifiers,
                characters: "",
                charactersIgnoringModifiers: ""
            )
        }
        let keyCycle = [HostDisplayInputEvent(
            kind: .keyDown,
            keyCode: keyCode,
            modifiers: modifiers.union(Self.deviceFlags(for: modifiers)),
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        ), HostDisplayInputEvent(
            kind: .keyUp,
            keyCode: keyCode,
            modifiers: modifiers.union(Self.deviceFlags(for: modifiers)),
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )]
        let releases = modifierReleaseTransitions.map {
            HostDisplayInputEvent(
                kind: .flagsChanged,
                keyCode: $0.keyCode,
                modifiers: $0.modifiers,
                characters: "",
                charactersIgnoringModifiers: ""
            )
        }
        return presses + keyCycle + releases
    }

    private static let physicalModifiers: [(flag: NSEvent.ModifierFlags, keyCode: UInt16, deviceFlag: NSEvent.ModifierFlags)] = [
        (.control, 59, .init(rawValue: 0x1)), // kVK_Control / NX_DEVICELCTLKEYMASK
        (.option, 58, .init(rawValue: 0x20)), // kVK_Option / NX_DEVICELALTKEYMASK
        (.shift, 56, .init(rawValue: 0x2)),   // kVK_Shift / NX_DEVICELSHIFTKEYMASK
        (.command, 55, .init(rawValue: 0x8))  // kVK_Command / NX_DEVICELCMDKEYMASK
    ]

    private static let physicalModifierMask: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command
    ]

    private static func deviceFlags(for modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        physicalModifiers.reduce(into: []) { result, modifier in
            if modifiers.contains(modifier.flag) {
                result.insert(modifier.deviceFlag)
            }
        }
    }

    /// A key that can be named on the command line. The names are the single
    /// source for both `lookup` and `pomme ui keys`, so the help cannot drift
    /// from what the helper accepts.
    struct NamedKey: Sendable {
        let names: [String]
        let keyCode: UInt16
        let characters: String
        let modifiers: NSEvent.ModifierFlags

        var name: String { names[0] }
        var aliases: [String] { Array(names.dropFirst()) }
    }

    /// A modifier spelled as a prefix on another key name, such as `cmd-t`.
    struct ModifierPrefix: Sendable {
        let prefixes: [String]
        let flag: NSEvent.ModifierFlags

        var prefix: String { prefixes[0] }
        var aliases: [String] { Array(prefixes.dropFirst()) }
    }

    static let namedKeys: [NamedKey] = [
        .init(names: ["return", "enter"], keyCode: 36, characters: "\r", modifiers: []),
        .init(names: ["tab"], keyCode: 48, characters: "\t", modifiers: []),
        .init(names: ["shift-tab"], keyCode: 48, characters: "\t", modifiers: [.shift]),
        .init(names: ["space"], keyCode: 49, characters: " ", modifiers: []),
        .init(names: ["escape", "esc"], keyCode: 53, characters: "\u{1b}", modifiers: []),
        .init(names: ["delete", "backspace"], keyCode: 51, characters: "\u{8}", modifiers: []),
        .init(names: ["forward-delete"], keyCode: 117, characters: functionKeyString(0xF728), modifiers: []),
        .init(names: ["home"], keyCode: 115, characters: functionKeyString(0xF729), modifiers: []),
        .init(names: ["end"], keyCode: 119, characters: functionKeyString(0xF72B), modifiers: []),
        .init(names: ["page-up"], keyCode: 116, characters: functionKeyString(0xF72C), modifiers: []),
        .init(names: ["page-down"], keyCode: 121, characters: functionKeyString(0xF72D), modifiers: []),
        .init(names: ["left"], keyCode: 123, characters: functionKeyString(0xF702), modifiers: []),
        .init(names: ["right"], keyCode: 124, characters: functionKeyString(0xF703), modifiers: []),
        .init(names: ["down"], keyCode: 125, characters: functionKeyString(0xF701), modifiers: []),
        .init(names: ["up"], keyCode: 126, characters: functionKeyString(0xF700), modifiers: []),
        .init(names: ["f1"], keyCode: 122, characters: functionKeyString(0xF704), modifiers: []),
        .init(names: ["f2"], keyCode: 120, characters: functionKeyString(0xF705), modifiers: []),
        .init(names: ["f3"], keyCode: 99, characters: functionKeyString(0xF706), modifiers: []),
        .init(names: ["f4"], keyCode: 118, characters: functionKeyString(0xF707), modifiers: []),
        .init(names: ["f5"], keyCode: 96, characters: functionKeyString(0xF708), modifiers: []),
        .init(names: ["f6"], keyCode: 97, characters: functionKeyString(0xF709), modifiers: []),
        .init(names: ["f7"], keyCode: 98, characters: functionKeyString(0xF70A), modifiers: []),
        .init(names: ["f8"], keyCode: 100, characters: functionKeyString(0xF70B), modifiers: []),
        .init(names: ["f9"], keyCode: 101, characters: functionKeyString(0xF70C), modifiers: []),
        .init(names: ["f10"], keyCode: 109, characters: functionKeyString(0xF70D), modifiers: []),
        .init(names: ["f11"], keyCode: 103, characters: functionKeyString(0xF70E), modifiers: []),
        .init(names: ["f12"], keyCode: 111, characters: functionKeyString(0xF70F), modifiers: []),
        .init(names: ["command-space", "cmd-space"], keyCode: 49, characters: " ", modifiers: [.command]),
    ]

    static let modifierPrefixes: [ModifierPrefix] = [
        .init(prefixes: ["command-", "cmd-"], flag: .command),
        .init(prefixes: ["control-", "ctrl-"], flag: .control),
        .init(prefixes: ["option-", "opt-", "alt-"], flag: .option),
        .init(prefixes: ["shift-"], flag: .shift),
    ]

    private static let namedKeysByName: [String: NamedKey] = namedKeys.reduce(into: [:]) { table, key in
        for name in key.names { table[name] = key }
    }

    static func lookup(_ name: String) -> HostDisplayKey? {
        let normalized = name.lowercased().replacingOccurrences(of: "+", with: "-")
        if let named = namedKeysByName[normalized] {
            return key(named.keyCode, characters: named.characters, modifiers: named.modifiers)
        }
        for modifier in modifierPrefixes {
            if let modified = modifiedKey(named: normalized, prefixes: modifier.prefixes, modifiers: modifier.flag) {
                return modified
            }
        }
        if name.count == 1, let character = name.first {
            return lookup(character: character)
        }
        return nil
    }

    static func lookup(character: Character) -> HostDisplayKey? {
        let string = String(character)
        if let base = baseKey(for: string) {
            return key(base.keyCode, characters: string, ignoring: base.characters)
        }
        if let shifted = shiftedKey(for: string) {
            return key(shifted.keyCode, characters: string, ignoring: shifted.characters, modifiers: [.shift])
        }
        return nil
    }

    private static func modifiedKey(named name: String, prefixes: [String], modifiers: NSEvent.ModifierFlags) -> HostDisplayKey? {
        for prefix in prefixes where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            guard let base = lookup(suffix) else {
                return nil
            }
            let combinedModifiers = base.modifiers.union(modifiers)
            return key(
                base.keyCode,
                // `characters` includes all logical modifiers, while AppKit
                // preserves Shift (and ignores every other modifier) in
                // `charactersIgnoringModifiers`. In particular, Tahoe
                // Recovery's Shift-Command-T Terminal shortcut requires "T"
                // in both fields.
                characters: eventCharacters(base.characters, modifiers: combinedModifiers),
                ignoring: eventCharactersIgnoringModifiers(
                    base.charactersIgnoringModifiers,
                    modifiers: combinedModifiers
                ),
                modifiers: combinedModifiers
            )
        }
        return nil
    }

    private static func eventCharacters(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> String {
        // AppKit reports a control chord's logical character as its ASCII
        // control character (for example, Control-C is ETX), while
        // `charactersIgnoringModifiers` remains the physical key. Sending
        // plain "c" here makes Tahoe Recovery append a literal c to the
        // shell line instead of interrupting the foreground rescue agent.
        let scalars = characters.unicodeScalars
        if modifiers.contains(.control),
           scalars.count == 1,
           let scalar = scalars.first,
           scalar.value <= 0x7F
        {
            let controlValue = scalar.value & 0x1F
            if controlValue != 0, let controlScalar = UnicodeScalar(controlValue) {
                return String(controlScalar)
            }
        }
        guard modifiers.contains(.shift) else {
            return characters
        }
        return characters.uppercased()
    }

    private static func eventCharactersIgnoringModifiers(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> String {
        guard modifiers.contains(.shift) else {
            return characters
        }
        return characters.uppercased()
    }

    private static func key(
        _ keyCode: UInt16,
        characters: String,
        ignoring: String? = nil,
        modifiers: NSEvent.ModifierFlags = []
    ) -> HostDisplayKey {
        HostDisplayKey(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            modifiers: modifiers
        )
    }

    private static func baseKey(for string: String) -> (keyCode: UInt16, characters: String)? {
        let mapping: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50, " ": 49, "\t": 48, "\n": 36, "\r": 36
        ]
        if let keyCode = mapping[string] {
            return (keyCode, string)
        }
        return nil
    }

    private static func shiftedKey(for string: String) -> (keyCode: UInt16, characters: String)? {
        let lowercased = string.lowercased()
        if lowercased != string, let key = baseKey(for: lowercased) {
            return key
        }
        let mapping: [String: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
            "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
            "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
        ]
        guard let base = mapping[string], let key = baseKey(for: base) else {
            return nil
        }
        return key
    }

    private static func functionKeyString(_ value: Int) -> String {
        String(UnicodeScalar(value)!)
    }
}
