import AppKit
import SwiftUI
import WallpaperMacCore

/// Installs an app-local event monitor only while the recorder is visible.
/// Unlike a global monitor it needs no Accessibility/Input Monitoring grant;
/// returning nil consumes the key so ⌘Q and friends cannot trigger app menus
/// or the old hot-key action during recording.
struct HotKeyRecorderView: NSViewRepresentable {
    let onRecord: (HotKeyShortcut) -> Void
    let onCancel: () -> Void

    final class Coordinator {
        var monitor: Any?
        var onRecord: ((HotKeyShortcut) -> Void)?
        var onCancel: (() -> Void)?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.onRecord = onRecord
        coordinator.onCancel = onCancel
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags
            let modifiers = Self.carbonModifiers(from: flags)
            if event.keyCode == 53, modifiers == 0 { // Escape cancels, never records.
                coordinator.onCancel?()
                return nil
            }
            let shortcut = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            coordinator.onRecord?(shortcut)
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onRecord = onRecord
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= HotKeyShortcut.commandModifier }
        if flags.contains(.shift) { modifiers |= HotKeyShortcut.shiftModifier }
        if flags.contains(.option) { modifiers |= HotKeyShortcut.optionModifier }
        if flags.contains(.control) { modifiers |= HotKeyShortcut.controlModifier }
        // Deliberately ignore .function, .numericPad, .capsLock and device
        // flags: they are not Carbon command modifiers and otherwise make F
        // keys/arrows look like different shortcuts.
        return modifiers
    }
}
