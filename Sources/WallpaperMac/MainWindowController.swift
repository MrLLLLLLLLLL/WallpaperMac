import AppKit
import Combine
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController {
    private var themeCancellable: AnyCancellable?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WallpaperMac"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isRestorable = false
        window.center()
        let initialTheme = ThemeStore.shared.activeTheme
        window.appearance = NSAppearance(named: initialTheme.colorScheme == .light ? .aqua : .darkAqua)
        window.contentView = NSHostingView(rootView: MainView())
        window.minSize = NSSize(width: MainWindowMetrics.minimumWindowWidth, height: 640)
        window.contentMinSize = NSSize(width: MainWindowMetrics.minimumWindowWidth, height: 640)
        super.init(window: window)
        window.delegate = self
        applyThemeAppearance(ThemeStore.shared.activeTheme)
        themeCancellable = ThemeStore.shared.$activeTheme
            .receive(on: RunLoop.main)
            .sink { [weak self] theme in
                self?.applyThemeAppearance(theme)
            }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyThemeAppearance(ThemeStore.shared.activeTheme)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.applyThemeAppearance(ThemeStore.shared.activeTheme)
        }
    }

    private func applyThemeAppearance(_ theme: AppThemeDefinition) {
        window?.appearance = NSAppearance(named: theme.colorScheme == .light ? .aqua : .darkAqua)
        window?.backgroundColor = NSColor(theme.palette.canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension MainWindowController: NSWindowDelegate {
    /// SwiftUI may replace the window's intrinsic minimum size during layout,
    /// so clamp user resizing explicitly. This keeps the complete library
    /// header visible at the minimum window width.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, MainWindowMetrics.minimumWindowWidth),
            height: max(frameSize.height, 640)
        )
    }

    /// Accessibility and programmatic resizing can bypass `windowWillResize`.
    /// Snap the window back so no header control can overflow its pane.
    func windowDidBecomeKey(_ notification: Notification) {
        applyThemeAppearance(ThemeStore.shared.activeTheme)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        let minimum = NSSize(width: MainWindowMetrics.minimumWindowWidth, height: 640)
        guard window.frame.width < minimum.width
                || window.frame.height < minimum.height else { return }
        var frame = window.frame
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        window.setFrame(frame, display: true)
    }
}
