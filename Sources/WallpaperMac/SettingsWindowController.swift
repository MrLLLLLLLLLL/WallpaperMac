import AppKit
import SwiftUI
import WallpaperMacCore

@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WallpaperMac 设置"
        window.isRestorable = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct SettingsView: View {
    static var defaultLibraryURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("WallpaperMac", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    @AppStorage(SettingsKey.libraryPath) private var libraryPath = SettingsView.defaultLibraryURL.path
    @AppStorage(SettingsKey.storageMode) private var storageMode = StorageMode.managedCopy.rawValue
    @AppStorage(SettingsKey.muted) private var muted = true
    @AppStorage(SettingsKey.loops) private var loops = true
    @AppStorage(SettingsKey.pauseOnBattery) private var pauseOnBattery = false
    @AppStorage(SettingsKey.pauseInFullScreen) private var pauseInFullScreen = false
    @AppStorage(SettingsKey.fitMode) private var fitMode = WallpaperFitMode.fill.rawValue
    @AppStorage(SettingsKey.webWallpaperInteractionEnabled) private var webWallpaperInteractionEnabled = false
    @AppStorage(SettingsKey.launchAtLogin) private var launchAtLogin = false
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheckUpdates = true
    @State private var launchAtLoginError: String?
    @State private var isSyncingLoginToggle = false
    @ObservedObject private var updateService = UpdateService.shared

    private var applicationVersionInfo: ApplicationVersionInfo {
        ApplicationVersionInfo(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            fallbackVersion: "0.2.6"
        )
    }

    var body: some View {
        Form {
            Section("壁纸库") {
                HStack {
                    Text(libraryPath)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择文件夹") { chooseLibraryFolder() }
                    Button("打开") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: libraryPath))
                    }
                }
                Picker("默认导入方式", selection: $storageMode) {
                    Text("复制到应用库").tag(StorageMode.managedCopy.rawValue)
                    Text("引用原文件").tag(StorageMode.externalReference.rawValue)
                }
            }
            Section("显示器") {
                Label("每块显示器独立应用壁纸", systemImage: "display.2")
                Text("请在主窗口的“显示器”分组中为每块屏幕单独选择壁纸。显示器断开后，原分配会保留并在重新连接时尝试恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("播放") {
                Toggle("视频和网页默认静音", isOn: $muted)
                Toggle("循环播放", isOn: $loops)
                Toggle("使用电池时暂停动态壁纸", isOn: $pauseOnBattery)
                Toggle("全屏应用时暂停动态壁纸", isOn: $pauseInFullScreen)
                Picker("适配方式", selection: $fitMode) {
                    ForEach(WallpaperFitMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Text("填充屏幕会裁剪边缘；完整显示会保留原始比例。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("交互") {
                Toggle("壁纸点击效果", isOn: $webWallpaperInteractionEnabled)
                Text("启用后，网页壁纸会移动到桌面图标层上方，以便直接点击网页；图片和视频壁纸仍保持点击穿透。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("快捷键") {
                Label("快捷键设置", systemImage: "command")
                Text("当前版本通过菜单栏、检查器和显示器分配控制壁纸；全局快捷键将在后续版本加入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("登录时启动", isOn: $launchAtLogin)
                HStack(spacing: 8) {
                    Circle()
                        .fill(LoginItemService.isEnabled ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text("系统登录项：\(LoginItemService.statusDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("软件更新") {
                updateSectionContent
            }
            Section("关于 WallpaperMac") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WallpaperMac")
                            .font(.headline)
                        Text(applicationVersionInfo.displayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 600, minHeight: 540)
        .onAppear {
            // Reflect external login-item changes without re-applying them.
            isSyncingLoginToggle = true
            launchAtLogin = LoginItemService.isEnabled
            isSyncingLoginToggle = false
            // First open of settings may still trigger a missed daily check.
            if autoCheckUpdates {
                updateService.runDailyCheckIfNeeded()
            }
        }
        .onChange(of: libraryPath) { _ in notifySettingsChanged() }
        .onChange(of: storageMode) { _ in notifySettingsChanged() }
        .onChange(of: muted) { _ in notifySettingsChanged() }
        .onChange(of: loops) { _ in notifySettingsChanged() }
        .onChange(of: pauseOnBattery) { _ in notifySettingsChanged() }
        .onChange(of: pauseInFullScreen) { _ in notifySettingsChanged() }
        .onChange(of: fitMode) { _ in notifySettingsChanged() }
        .onChange(of: webWallpaperInteractionEnabled) { _ in notifySettingsChanged() }
        .onChange(of: launchAtLogin) { enabled in
            guard !isSyncingLoginToggle else { return }
            updateLaunchAtLogin(enabled)
        }
    }

    @ViewBuilder
    private var updateSectionContent: some View {
        HStack {
            Text("当前版本 \(applicationVersionInfo.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if updateService.phase == .checking {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("检查更新") { updateService.checkForUpdates(userInitiated: true) }
                    .disabled(updateService.isBusy)
            }
        }
        Toggle("启动时每日检查一次", isOn: $autoCheckUpdates)

        switch updateService.phase {
        case .idle, .checking:
            EmptyView()
        case .upToDate(let version):
            Text("当前已是最新版本（\(version)）")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let update):
            VStack(alignment: .leading, spacing: 8) {
                Text("发现新版本 \(update.version)")
                    .font(.headline)
                if let publishedAt = update.publishedAt {
                    Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !update.releaseNotes.isEmpty {
                    ScrollView {
                        Text(update.releaseNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
                HStack {
                    Button("立即更新") { updateService.installUpdate(update) }
                        .keyboardShortcut(.defaultAction)
                    Button("稍后再说") {
                        updateService.dismissPrompt()
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.08))
            )
        case .downloading(let update, let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("正在下载 \(update.version)")
                    .font(.headline)
                if let progress, let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                    Text("\(ByteCountFormatter.string(fromByteCount: progress.bytesReceived, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在下载…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("下载完成后会自动校验并安装，应用将重启。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installing(let update):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("正在安装 \(update.version)，应用即将退出…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("重试") { updateService.checkForUpdates(userInitiated: true) }
            }
        }
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择壁纸库位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: libraryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        libraryPath = url.path
        notifySettingsChanged()
    }

    @MainActor
    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            launchAtLoginError = nil
            UserDefaults.standard.set(enabled, forKey: SettingsKey.launchAtLogin)
            notifySettingsChanged()
        } catch {
            launchAtLogin = LoginItemService.isEnabled
            launchAtLoginError = "登录项设置失败：\(error.localizedDescription)"
        }
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: .wallpaperMacSettingsChanged, object: nil)
    }
}

enum SettingsKey {
    static let libraryPath = "WallpaperMac.libraryPath"
    static let storageMode = "WallpaperMac.storageMode"
    static let muted = "WallpaperMac.muted"
    static let loops = "WallpaperMac.loops"
    static let pauseOnBattery = "WallpaperMac.pauseOnBattery"
    static let pauseInFullScreen = "WallpaperMac.pauseInFullScreen"
    static let fitMode = "WallpaperMac.fitMode"
    static let webWallpaperInteractionEnabled = "WallpaperMac.webWallpaperInteractionEnabled"
    static let launchAtLogin = "WallpaperMac.launchAtLogin"
    static let onboardingCompleted = "WallpaperMac.onboardingCompleted"
    static let autoCheckUpdates = "WallpaperMac.autoCheckUpdates"
    static let lastUpdateCheckDate = "WallpaperMac.lastUpdateCheckDate"
}

extension Notification.Name {
    static let wallpaperMacSettingsChanged = Notification.Name("WallpaperMacSettingsChanged")
}
