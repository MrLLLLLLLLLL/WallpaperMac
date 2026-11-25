import Foundation

/// A keyboard shortcut stored using Carbon's key-code and modifier masks.
/// Keeping the persisted value independent of NSEvent makes it stable across
/// keyboard layouts and lets validation/display be tested without AppKit.
public struct HotKeyShortcut: Codable, Equatable, Sendable {
    public static let commandModifier: UInt32 = 0x0100
    public static let shiftModifier: UInt32 = 0x0200
    public static let optionModifier: UInt32 = 0x0800
    public static let controlModifier: UInt32 = 0x1000

    public static let defaultHideHidden = HotKeyShortcut(
        keyCode: 4, // kVK_ANSI_H
        modifiers: controlModifier | optionModifier
    )

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        let allowed = Self.commandModifier | Self.shiftModifier | Self.optionModifier | Self.controlModifier
        return keyCode <= 0x7f
            && modifiers & ~allowed == 0
            && modifiers & (Self.commandModifier | Self.optionModifier | Self.controlModifier) != 0
    }

    /// Shortcuts that are essential to the app/macOS even if Carbon happens to
    /// accept their registration. Carbon's eventAlreadyRegisteredErr remains
    /// the authority for shortcuts owned by other applications.
    public var reservedReason: String? {
        let commandOnly = modifiers == Self.commandModifier
        let commandShift = modifiers == (Self.commandModifier | Self.shiftModifier)
        let commandOption = modifiers == (Self.commandModifier | Self.optionModifier)
        let controlCommand = modifiers == (Self.controlModifier | Self.commandModifier)
        if commandOnly, [4, 12, 13, 46, 48, 49].contains(keyCode) {
            return "该组合用于系统或应用常用操作（如退出、关闭窗口、切换应用或 Spotlight）"
        }
        if commandShift, [18, 19, 20, 21, 23].contains(keyCode) {
            return "该组合与 macOS 截图快捷键冲突"
        }
        if commandOption, keyCode == 53 {
            return "该组合与“强制退出应用”冲突"
        }
        if controlCommand, keyCode == 12 {
            return "该组合与“锁定屏幕”冲突"
        }
        return nil
    }

    public var validationIssue: String? {
        if !isValid { return "快捷键必须包含 ⌃、⌥ 或 ⌘ 中至少一个修饰键" }
        return reservedReason
    }

    /// NSMenuItem uses characters rather than Carbon key codes. Return an
    /// empty string for keys that have no menu equivalent instead of leaving
    /// the previous menu shortcut active by accident.
    public var menuKeyEquivalent: String {
        if let name = Self.keyNames[keyCode], name.count == 1 {
            return name.lowercased()
        }
        return Self.menuSpecialKeys[keyCode] ?? ""
    }

    private static let menuSpecialKeys: [UInt32: String] = [
        36: "\r", 48: "\t", 49: " ", 51: "\u{7f}", 53: "\u{1b}",
        96: "\u{f708}", 97: "\u{f709}", 98: "\u{f70a}", 99: "\u{f706}", 100: "\u{f70b}",
        101: "\u{f70c}", 103: "\u{f70e}", 109: "\u{f70d}", 111: "\u{f70f}",
        115: "\u{f729}", 116: "\u{f72c}", 118: "\u{f707}", 119: "\u{f72b}", 120: "\u{f705}",
        121: "\u{f72d}", 122: "\u{f704}", 123: "\u{f702}", 124: "\u{f703}", 125: "\u{f701}", 126: "\u{f700}",
    ]

    public var displayString: String {
        var result = ""
        if modifiers & Self.controlModifier != 0 { result += "⌃" }
        if modifiers & Self.optionModifier != 0 { result += "⌥" }
        if modifiers & Self.shiftModifier != 0 { result += "⇧" }
        if modifiers & Self.commandModifier != 0 { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "键码 \(keyCode)")
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "⇥", 49: "␣", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
        111: "F12", 115: "↖", 116: "⇞", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func load(from defaults: UserDefaults, key: String) -> HotKeyShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.validationIssue == nil else {
            return .defaultHideHidden
        }
        return shortcut
    }

    public func save(to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}
