import AppKit
import Carbon.HIToolbox

/// Registers the app-wide shortcut for re-hiding hidden wallpapers.
/// Carbon hot keys work without Accessibility or Input Monitoring grants.
@MainActor
final class GlobalHotKeyService {
    static let shared = GlobalHotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private let signature: OSType = 0x574D484B // 'WMHK'
    private let identifier: UInt32 = 1

    private init() {}

    func register(action: @escaping () -> Void) {
        self.action = action
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, _, _ in
            Task { @MainActor in
                GlobalHotKeyService.shared.perform()
            }
            return noErr
        }
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        if handlerStatus != noErr {
            NSLog("WallpaperMac global hot key handler failed: %d", handlerStatus)
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_H),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("WallpaperMac global hot key registration failed: %d", status)
            hotKeyRef = nil
        }
    }

    fileprivate func perform() {
        action?()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
