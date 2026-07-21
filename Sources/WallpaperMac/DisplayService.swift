import AppKit
import Combine
import CoreGraphics

@MainActor
final class DisplayService: ObservableObject {
    struct Display: Identifiable {
        let id: String
        let name: String
        let screen: NSScreen
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
            let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = displayNumber.map { "display-\($0.uint32Value)" } ?? "display-\(index)"
            return Display(id: id, name: screen.localizedName.isEmpty ? "显示器 \(index + 1)" : screen.localizedName, screen: screen)
        }
    }
}
