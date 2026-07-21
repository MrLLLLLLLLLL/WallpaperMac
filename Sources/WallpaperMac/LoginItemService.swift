import Foundation
import ServiceManagement

/// Keeps the user's launch-at-login preference in sync with macOS Login Items.
@MainActor
enum LoginItemService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需要在系统设置中批准"
        case .notRegistered:
            return "未启用"
        case .notFound:
            return "当前应用包不可注册"
        @unknown default:
            return "状态未知"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
