import AppKit
import Carbon

struct ShortcutBinding: Codable, Equatable, Identifiable {
    var id: UInt32
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled = true
    var title: String {
        switch id {
        case 1: return "Capture area"
        case 2: return "Capture screen"
        case 3: return "Start / stop recording"
        case 4: return "Scrolling capture / add frame"
        default: return "Finish scrolling capture"
        }
    }
    static let keys: [(String, UInt32)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97), ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111), ("F13", 105), ("F14", 107), ("F15", 113), ("F16", 106), ("F17", 64), ("F18", 79), ("F19", 80), ("F20", 90),
        ("Space", 49), ("Return", 36), ("Tab", 48), ("Delete", 51), ("Forward Delete", 117), ("Escape", 53), ("←", 123), ("→", 124), ("↓", 125), ("↑", 126), ("Home", 115), ("End", 119), ("Page Up", 116), ("Page Down", 121),
        ("-", 27), ("=", 24), ("[", 33), ("]", 30), (";", 41), ("'", 39), (",", 43), (".", 47), ("/", 44), ("\\", 42), ("`", 50)
    ]
    var key: String { Self.keys.first { $0.1 == keyCode }?.0 ?? "?" }
    var menuKey: String {
        let special: [UInt32: UInt32] = [49: 32, 36: 13, 48: 9, 51: 8, 117: 0xF728, 53: 27, 123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700, 115: 0xF729, 119: 0xF72B, 116: 0xF72C, 121: 0xF72D]
        if let value = special[keyCode], let scalar = UnicodeScalar(value) { return String(scalar) }
        if key.count == 1 { return key.lowercased() }
        if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...20).contains(number), let scalar = UnicodeScalar(UInt32(0xF703 + number)) { return String(scalar) }
        return ""
    }
    var label: String {
        guard enabled else { return "Off" }
        return [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")].filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }
    var eventModifiers: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        for (carbon, native) in [(controlKey, NSEvent.ModifierFlags.control), (optionKey, .option), (shiftKey, .shift), (cmdKey, .command)] {
            if modifiers & UInt32(carbon) != 0 { value.insert(native) }
        }
        return value
    }
    static var defaults: [ShortcutBinding] {
        [ShortcutBinding(id: 1, keyCode: 21, modifiers: UInt32(controlKey | cmdKey | shiftKey)),
         ShortcutBinding(id: 2, keyCode: 20, modifiers: UInt32(controlKey | cmdKey | shiftKey)),
         ShortcutBinding(id: 3, keyCode: 23, modifiers: UInt32(controlKey | cmdKey | shiftKey)),
         ShortcutBinding(id: 4, keyCode: 22, modifiers: UInt32(controlKey | cmdKey | shiftKey)),
         ShortcutBinding(id: 5, keyCode: 36, modifiers: UInt32(controlKey | cmdKey | shiftKey))]
    }
    static func validationError(_ bindings: [ShortcutBinding]) -> String? {
        guard bindings.map(\.id).sorted() == [1, 2, 3, 4, 5] else { return "Configure each of the five actions once." }
        let enabled = bindings.filter(\.enabled)
        let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        guard enabled.allSatisfy({ binding in
            let isFunction = keys.contains { $0.1 == binding.keyCode && $0.0.hasPrefix("F") && $0.0 != "Forward Delete" }
            return keys.contains { $0.1 == binding.keyCode } && binding.modifiers & ~allowedModifiers == 0 &&
                (isFunction || binding.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0)
        }) else { return "Use Command, Control, or Option with a key, or choose an F-key. Shift alone is reserved for typing." }
        guard Set(enabled.map { "\($0.keyCode):\($0.modifiers)" }).count == enabled.count else { return "Choose a different key combination for each action." }
        return nil
    }
}

enum BackdropStyle: String, Codable, CaseIterable, Identifiable {
    case ocean, sunset, graphite, paper, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colors: (NSColor, NSColor) {
        switch self {
        case .ocean: return (.systemIndigo, .systemTeal)
        case .sunset: return (.systemOrange, .systemPink)
        case .graphite: return (.darkGray, .black)
        case .paper: return (.white, .white)
        case .custom: return (.systemIndigo, .systemTeal)
        }
    }
}

struct BackdropSettings: Codable, Equatable {
    var style: BackdropStyle = .ocean
    var padding: Double = 7
    // Embedded image belongs to the capture; editing the source file cannot break its history.
    var customImage: Data?
}

struct AppPreferences: Codable, Equatable {
    var shortcuts = ShortcutBinding.defaults
    var captureDelay = 0
    var includeCursor = false
    var windowShadow = true
    var openEditorAfterCapture = false
    var imageFormat = "png"
    var recordSystemAudio = false
    var recordingFPS = 30
    var recordingMaxWidth = 3840
    var backdrop = BackdropSettings()
}

// Older settings contain only the original three actions. Preserve user bindings
// and add the two scrolling actions; disable a new binding if it would conflict.
extension AppPreferences {
    mutating func migrateShortcuts() {
        for var binding in ShortcutBinding.defaults where !shortcuts.contains(where: { $0.id == binding.id }) {
            if shortcuts.contains(where: { $0.enabled && $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers }) { binding.enabled = false }
            shortcuts.append(binding)
        }
        shortcuts.sort { $0.id < $1.id }
    }
}
