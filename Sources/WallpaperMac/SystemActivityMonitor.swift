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
    private var isScreenAsleep = false
    private var isSessionInactive = false

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

        // Display sleep / wake and session lock / fast-user-switch all change
        // whether rendering is worthwhile. Without these, wallpapers keep
        // decoding and drawing while the lid is closed or the screen is locked.
        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenAsleep = true
                self?.evaluate()
            }
        }
        observers.append((workspaceCenter, sleepToken))
        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenAsleep = false
                self?.evaluate()
            }
        }
        observers.append((workspaceCenter, wakeToken))
        let resignToken = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSessionInactive = true
                self?.evaluate()
            }
        }
        observers.append((workspaceCenter, resignToken))
        let activeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSessionInactive = false
                self?.evaluate()
            }
        }
        observers.append((workspaceCenter, activeToken))

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
            fullScreenDisplayIDs: frontmostFullScreenDisplayIDs(),
            isScreenAsleep: isScreenAsleep,
            isSessionInactive: isSessionInactive
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
        let primaryHeight = screens.first?.frame.height ?? 0
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
            // CGWindowList rects are Quartz (origin top-left of the main
            // screen); NSScreen.frame is Cocoa (origin bottom-left). Convert
            // before comparing, otherwise stacked/offset secondary displays
            // never match and the fullscreen pause silently stops working.
            let cocoaRect = FullscreenGeometry.cocoaRect(fromQuartz: rect, primaryScreenHeight: primaryHeight)
            guard let screen = screens.first(where: { screen in
                FullscreenGeometry.isFullscreen(rect: cocoaRect, on: screen.frame)
            }) else { continue }
            result.insert(DisplayIdentityProvider.identity(for: screen).profileID)
        }
        return result
    }
}
