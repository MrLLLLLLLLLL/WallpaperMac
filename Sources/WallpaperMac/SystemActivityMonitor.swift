import AppKit
import CoreGraphics
import IOKit.ps
import WallpaperMacCore

/// Monitors system conditions that can temporarily suspend dynamic wallpapers.
///
/// Power-source changes are sampled by a lightweight timer because AppKit does
/// not expose a public `ProcessInfo.powerStateDidChangeNotification` on the
/// supported macOS SDKs. Frontmost-app and display changes are event-driven.
@MainActor
final class SystemActivityMonitor {
    private let onChange: (PlaybackActivityState) -> Void
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?
    private var lastState: PlaybackActivityState?

    init(onChange: @escaping (PlaybackActivityState) -> Void) {
        self.onChange = onChange

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let activationToken = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        observers.append((workspaceCenter, activationToken))

        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        observers.append((NotificationCenter.default, screenToken))

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        evaluate()
    }

    deinit {
        observers.forEach { $0.center.removeObserver($0.token) }
        timer?.invalidate()
    }

    func evaluate() {
        let state = PlaybackActivityState(
            isOnBattery: isUsingBatteryPower(),
            fullScreenDisplayIDs: frontmostFullScreenDisplayIDs()
        )
        guard state != lastState else { return }
        lastState = state
        onChange(state)
    }

    private func isUsingBatteryPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            if state == kIOPSBatteryPowerValue {
                return true
            }
            if state == kIOPSACPowerValue {
                return false
            }
        }
        return false
    }

    private func frontmostFullScreenDisplayIDs() -> Set<String> {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return []
        }
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        let screens = NSScreen.screens
        let pid = application.processIdentifier
        var result = Set<String>()
        for info in windowInfo {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else { continue }
            guard let screen = screens.first(where: { screen in
                let frame = screen.frame
                return abs(rect.minX - frame.minX) < 2 &&
                    abs(rect.minY - frame.minY) < 2 &&
                    abs(rect.width - frame.width) < 2 &&
                    abs(rect.height - frame.height) < 2
            }) else { continue }
            result.insert(DisplayIdentityProvider.identity(for: screen).profileID)
        }
        return result
    }
}
