import Carbon.HIToolbox
import WallpaperMacCore

/// Checks the system-owned symbolic shortcuts exposed by Carbon. This is a
/// useful preflight, not a complete third-party registry: Carbon's ordinary
/// hot keys are non-exclusive, and another app may register the same pair.
enum SystemHotKeyConflictChecker {
    static func hasConflict(with shortcut: HotKeyShortcut) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let array else { return false }
        guard let raw = array.takeRetainedValue() as? [[String: Any]] else { return false }
        return raw.contains { entry in
            guard let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool, enabled,
                  let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber else {
                return false
            }
            return code.uint32Value == shortcut.keyCode && modifiers.uint32Value == shortcut.modifiers
        }
    }
}
