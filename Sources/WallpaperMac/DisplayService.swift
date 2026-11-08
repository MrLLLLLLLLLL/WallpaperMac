import AppKit
import Combine
import CoreGraphics
import WallpaperMacCore

@MainActor
final class DisplayService: ObservableObject {
    struct Display: Identifiable {
        let id: String
        let name: String
        let screen: NSScreen
        let identity: DisplayIdentity
    }

    @Published private(set) var displays: [Display] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func refresh() {
        displays = NSScreen.screens.enumerated().map { index, screen in
            let identity = DisplayIdentityProvider.identity(for: screen)
            let name = screen.localizedName.isEmpty ? "显示器 \(index + 1)" : screen.localizedName
            return Display(id: identity.profileID, name: name, screen: screen, identity: identity)
        }
    }

    func currentIdentities() -> [DisplayIdentity] {
        NSScreen.screens.map(DisplayIdentityProvider.identity(for:))
    }
}
