import AppKit
import Carbon.HIToolbox
import WallpaperMacCore

enum HotKeyRegistrationResult: Equatable {
    case success
    case invalid(String)
    case conflict(String)
    case failure(String)

    var message: String? {
        switch self {
        case .success: return nil
        case .invalid(let message), .conflict(let message), .failure(let message): return message
        }
    }
}

/// Registers the app-wide shortcut for re-hiding hidden wallpapers.
/// Carbon hot keys work without Accessibility or Input Monitoring grants.
@MainActor
final class GlobalHotKeyService: ObservableObject {
    static let shared = GlobalHotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private let signature: OSType = 0x574D484B // 'WMHK'
    private var nextIdentifier: UInt32 = 1

    @Published private(set) var currentShortcut: HotKeyShortcut = .defaultHideHidden
    /// The user's saved choice, which can differ from the active shortcut when
    /// a previously valid combination can no longer be registered at launch.
    @Published private(set) var selectedShortcut: HotKeyShortcut = .defaultHideHidden
    @Published private(set) var isHotKeyRegistered = false
    @Published private(set) var lastRegistrationResult: HotKeyRegistrationResult?
    /// While recording in Settings, the recorder must not trigger the action
    /// it is trying to replace.
    var isRecordingHotKey = false

    private init() {}

    func register(action: @escaping () -> Void) {
        self.action = action
        let shortcut = HotKeyShortcut.load(from: .standard, key: SettingsKey.hideHiddenHotKey)
        selectedShortcut = shortcut
        _ = updateShortcut(shortcut)
    }

    /// Attempts the new registration before releasing the old one. A conflict
    /// therefore never leaves the user without their previous shortcut.
    @discardableResult
    func updateShortcut(_ shortcut: HotKeyShortcut) -> HotKeyRegistrationResult {
        if let issue = shortcut.validationIssue {
            let result = HotKeyRegistrationResult.invalid(issue)
            lastRegistrationResult = result
            return result
        }
        if shortcut == currentShortcut, hotKeyRef != nil {
            lastRegistrationResult = .success
            return .success
        }
        if SystemHotKeyConflictChecker.hasConflict(with: shortcut) {
            let result = HotKeyRegistrationResult.conflict(
                "快捷键 \(shortcut.displayString) 与 macOS 系统快捷键冲突，请换一个。"
            )
            lastRegistrationResult = result
            return result
        }
        if let handlerResult = installHandlerIfNeeded() {
            lastRegistrationResult = handlerResult
            return handlerResult
        }

        var newRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: nextIdentifier)
        nextIdentifier &+= 1
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        guard status == noErr, let newRef else {
            let result: HotKeyRegistrationResult
            if status == eventHotKeyExistsErr {
                result = .conflict("快捷键 \(shortcut.displayString) 注册冲突（错误码 \(status)），请换一个。macOS 无法枚举所有第三方占用。")
            } else {
                result = .failure("快捷键 \(shortcut.displayString) 注册失败（错误码 \(status)），请换一个。")
            }
            lastRegistrationResult = result
            return result
        }

        if let oldRef = hotKeyRef {
            let unregisterStatus = UnregisterEventHotKey(oldRef)
            guard unregisterStatus == noErr else {
                // Roll back the newly registered key and keep the old one
                // active rather than losing both registrations.
                UnregisterEventHotKey(newRef)
                let result = HotKeyRegistrationResult.failure(
                    "无法替换当前快捷键（注销错误码 \(unregisterStatus)），请重试。"
                )
                lastRegistrationResult = result
                return result
            }
        }
        hotKeyRef = newRef
        currentShortcut = shortcut
        selectedShortcut = shortcut
        isHotKeyRegistered = true
        lastRegistrationResult = .success
        return .success
    }

    private func installHandlerIfNeeded() -> HotKeyRegistrationResult? {
        guard handlerRef == nil else { return nil }
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
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard status == noErr else {
            return .failure("无法安装全局快捷键处理器（错误码 \(status)）。")
        }
        return nil
    }

    fileprivate func perform() {
        guard !isRecordingHotKey else { return }
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
