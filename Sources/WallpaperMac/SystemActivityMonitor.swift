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
    private let onChange: (Bool) -> Void
    private var policy = PlaybackPolicy()
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?
    private var lastPausedState: Bool?

    init(onChange: @escaping (Bool) -> Void) {
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

    func update(policy: PlaybackPolicy) {
        self.policy = policy
        evaluate()
    }

    private func evaluate() {
        let paused = policy.shouldPauseDynamicWallpaper(
            isOnBattery: isUsingBatteryPower(),
            isFullScreenAppActive: isFrontmostApplicationFullScreen()
        )
        guard paused != lastPausedState else { return }
        lastPausedState = paused
        onChange(paused)
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

    private func isFrontmostApplicationFullScreen() -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        let screenFrames = NSScreen.screens.map(\.frame)
        let pid = application.processIdentifier
        return windowInfo.contains { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else {
                return false
            }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else { return false }
            return screenFrames.contains { frame in
                abs(rect.minX - frame.minX) < 2 &&
                    abs(rect.minY - frame.minY) < 2 &&
                    abs(rect.width - frame.width) < 2 &&
                    abs(rect.height - frame.height) < 2
            }
        }
    }
}
