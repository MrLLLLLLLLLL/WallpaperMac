import AppKit
import Combine
import SwiftUI
import WallpaperMacCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private var themeCancellable: AnyCancellable?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WallpaperMac 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isRestorable = false
        window.center()
        let initialTheme = ThemeStore.shared.activeTheme
        window.appearance = NSAppearance(named: initialTheme.colorScheme == .light ? .aqua : .darkAqua)
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
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
    @AppStorage(SettingsKey.autoInstallUpdates) private var autoInstallUpdates = false
    @AppStorage(SettingsKey.lockScreenSyncEnabled) private var lockScreenSyncEnabled = false
    @ObservedObject private var lockScreenService = LockScreenWallpaperService.shared
    @State private var launchAtLoginError: String?
    @State private var isSyncingLoginToggle = false
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var category: SettingsCategory = .general
    @State private var hideHiddenHotKey = HotKeyShortcut.defaultHideHidden
    @State private var hotKeyMessage: String?
    @State private var isRecordingHotKey = false
    @State private var steamLoggedIn = false
    @State private var steamUsername: String = UserDefaults.standard.string(forKey: SteamSessionStore.usernameDefaultsKey) ?? ""
    @State private var steamLoginError: String?
    @State private var isSteamLoginPresented = false
    private let steamLoginService = SteamLoginService()

    private var applicationVersionInfo: ApplicationVersionInfo {
        ApplicationVersionInfo(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            fallbackVersion: ApplicationVersionInfo.developmentFallbackVersion
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 180)
            ThemeVerticalHairline()
            VStack(spacing: 0) {
                updateBanner
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        contentHeader
                        content
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .id(themeStore.activeTheme.id)
        .frame(minWidth: 720, minHeight: 560)
        .background(AppTheme.Palette.canvas)
        .tint(AppTheme.Palette.accent)
        .preferredColorScheme(themeStore.activeTheme.colorScheme)
        .onAppear {
            // Reflect external login-item changes without re-applying them.
            isSyncingLoginToggle = true
            launchAtLogin = LoginItemService.isEnabled
            isSyncingLoginToggle = false
            // First open of settings may still trigger a missed daily check.
            updateService.updateAutomaticPreferences()
            hideHiddenHotKey = GlobalHotKeyService.shared.selectedShortcut
            hotKeyMessage = GlobalHotKeyService.shared.lastRegistrationResult?.message
        }
        .onChange(of: libraryPath) { _ in notifySettingsChanged() }
        .onChange(of: storageMode) { _ in notifySettingsChanged() }
        .onChange(of: muted) { _ in notifySettingsChanged() }
        .onChange(of: loops) { _ in notifySettingsChanged() }
        .onChange(of: pauseOnBattery) { _ in notifySettingsChanged() }
        .onChange(of: pauseInFullScreen) { _ in notifySettingsChanged() }
        .onChange(of: fitMode) { _ in notifySettingsChanged() }
        .onChange(of: webWallpaperInteractionEnabled) { _ in notifySettingsChanged() }
        .onChange(of: autoCheckUpdates) { enabled in
            if !enabled { autoInstallUpdates = false }
            updateService.updateAutomaticPreferences()
        }
        .onChange(of: autoInstallUpdates) { enabled in
            // Auto-install includes the daily check; enabling it never leaves
            // a contradictory "install automatically but never check" state.
            if enabled { autoCheckUpdates = true }
            updateService.updateAutomaticPreferences()
        }
        .onChange(of: lockScreenSyncEnabled) { _ in
            lockScreenService.updatePreference()
        }
        .onChange(of: isRecordingHotKey) { recording in
            GlobalHotKeyService.shared.isRecordingHotKey = recording
        }
        .onChange(of: category) { _ in
            isRecordingHotKey = false
        }
        .onDisappear {
            isRecordingHotKey = false
            GlobalHotKeyService.shared.isRecordingHotKey = false
        }
        .onChange(of: launchAtLogin) { enabled in
            guard !isSyncingLoginToggle else { return }
            updateLaunchAtLogin(enabled)
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置")
                    .font(AppTheme.Typography.display(18))
                    .foregroundStyle(AppTheme.Palette.text)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 72)

            ThemeHairline()

            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { item in
                    SettingsCategoryRow(category: item, isSelected: category == item) {
                        category = item
                    }
                }
            }
            .padding(8)

            Spacer()

            Text("WallpaperMac \(applicationVersionInfo.version)")
                .font(AppTheme.Typography.mono(9))
                .foregroundStyle(AppTheme.Palette.textTertiary)
                .padding(16)
        }
        .background(AppTheme.Palette.sidebar)
    }

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(category.title)
                .font(AppTheme.Typography.display(24))
                .foregroundStyle(AppTheme.Palette.text)
            Text(category.subtitle)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .general:
            settingsSection("壁纸库") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(libraryPath)
                        .font(AppTheme.Typography.mono(9))
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("迁移壁纸库…") { chooseLibraryFolder() }
                            .buttonStyle(AccentActionButtonStyle(compact: true))
                        Button("打开") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: libraryPath))
                        }
                        .buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
                ThemeHairline()
                settingsPickerRow(
                    "默认导入方式",
                    description: "复制到应用库会保留独立副本；引用原文件只保存位置。"
                ) {
                    Picker("默认导入方式", selection: $storageMode) {
                        Text("复制到应用库").tag(StorageMode.managedCopy.rawValue)
                        Text("引用原文件").tag(StorageMode.externalReference.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            settingsSection("显示器") {
                HStack(spacing: 10) {
                    Image(systemName: "display.2")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("每块显示器独立应用壁纸")
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.Palette.text)
                        Text("在主窗口的显示器工作区分配壁纸与队列，断开的显示器会保留原记录。")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("打开显示器总览") {
                        (NSApp.delegate as? AppDelegate)?.showMainWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            NotificationCenter.default.post(name: .wallpaperMacShowDisplaysOverview, object: nil)
                        }
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
            }

        case .appearance:
            settingsSection("主题") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(AppThemeDefinition.all) { theme in
                        ThemePreviewCard(
                            theme: theme,
                            isSelected: themeStore.activeTheme.id == theme.id
                        ) {
                            themeStore.select(theme)
                        }
                    }
                }
                Text("主题会立即应用并保存在本机；浅色主题会同时切换窗口和系统控件外观。")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .playback:
            settingsSection("默认播放") {
                settingsToggle("视频和网页默认静音", description: "避免动态壁纸意外播放声音。", binding: $muted)
                ThemeHairline()
                settingsToggle("循环播放", description: "动态壁纸播放结束后从头开始。", binding: $loops)
                ThemeHairline()
                settingsPickerRow("全局适配方式", description: fitModeDescription) {
                    Picker("全局适配方式", selection: $fitMode) {
                        ForEach(WallpaperFitMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            settingsSection("节能与全屏") {
                settingsToggle("使用电池时暂停动态壁纸", description: "接入电源后恢复播放。", binding: $pauseOnBattery)
                ThemeHairline()
                settingsToggle("全屏应用时暂停动态壁纸", description: "只暂停全屏窗口所在的显示器。", binding: $pauseInFullScreen)
            }

        case .interaction:
            settingsSection("网页壁纸") {
                settingsToggle(
                    "壁纸点击效果",
                    description: "启用后网页壁纸会移动到桌面图标层上方，以便直接点击网页；图片和视频壁纸保持点击穿透。",
                    binding: $webWallpaperInteractionEnabled
                )
            }

            settingsSection("锁屏壁纸") {
                settingsToggle(
                    "同步当前壁纸到锁屏",
                    description: "使用当前壁纸的静态预览同步系统桌面图片：图片使用原图，视频使用缩略图，网页使用当前页面快照。macOS 是否将系统桌面图片用于锁屏由系统决定，不会修改 FileVault 登录界面。",
                    binding: $lockScreenSyncEnabled
                )
                if let error = lockScreenService.lastError {
                    Text(error)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsSection("快捷键") {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "command")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("关闭隐藏壁纸")
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.Palette.text)
                        Text("在系统范围内立即重新隐藏隐藏壁纸；重新显示仍需密码。")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(hideHiddenHotKey.displayString)
                        .font(AppTheme.Typography.mono(10, weight: .semibold))
                        .foregroundStyle(AppTheme.Palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(AppTheme.Palette.accentWash)
                        )
                }
                HStack(spacing: 8) {
                    Button(isRecordingHotKey ? "正在等待按键…" : "自定义快捷键…") {
                        hotKeyMessage = nil
                        isRecordingHotKey = true
                    }
                    .buttonStyle(AccentActionButtonStyle(compact: true))
                    .disabled(isRecordingHotKey)
                    Button("恢复默认") { applyHideHiddenHotKey(.defaultHideHidden) }
                        .buttonStyle(QuietButtonStyle(compact: true))
                    if isRecordingHotKey {
                        Button("取消") { isRecordingHotKey = false }
                            .buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
                if isRecordingHotKey {
                    HStack(spacing: 8) {
                        HotKeyRecorderView(
                            onRecord: { shortcut in applyHideHiddenHotKey(shortcut) },
                            onCancel: { isRecordingHotKey = false }
                        )
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        Text("请按下新快捷键，需包含 ⌃、⌥ 或 ⌘ 中至少一个。系统快捷键会先预检，注册失败会保留原快捷键。")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("提示：macOS 无法枚举所有第三方应用的普通全局热键；若出现双重响应，请更换组合。")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hotKeyMessage {
                    Text(hotKeyMessage)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(hotKeyMessage == "快捷键已更新。" ? AppTheme.Palette.applied : AppTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .steam:
            settingsSection("下载账号") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ThemeStatusDot(
                            color: steamLoggedIn ? AppTheme.Palette.applied : AppTheme.Palette.textTertiary,
                            size: 5
                        )
                        Text(steamLoggedIn
                             ? "已登录：\(steamUsername.isEmpty ? "（未知账号）" : steamUsername)"
                             : "未登录")
                            .font(AppTheme.Typography.body)
                            .foregroundStyle(AppTheme.Palette.text)
                        Spacer()
                        if steamLoggedIn {
                            Button("退出登录") {
                                Task { await steamLogout() }
                            }
                            .buttonStyle(QuietButtonStyle(compact: true))
                        } else {
                            Button("登录…") {
                                isSteamLoginPresented = true
                            }
                            .buttonStyle(AccentActionButtonStyle(compact: true))
                        }
                    }
                    Text("浏览创意工坊列表不需要登录；下载壁纸需要拥有 Wallpaper Engine 的 Steam 账号。密码只交给 SteamCMD 的 stdin，本应用不保存密码；登录成功后会话缓存在本地 SteamHome。")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let steamLoginError {
                        Text(steamLoginError)
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("打开创意工坊浏览…") {
                        (NSApp.delegate as? AppDelegate)?.showMainWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NotificationCenter.default.post(name: .wallpaperMacShowSteamWorkshopBrowse, object: nil)
                        }
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
            }
            .sheet(isPresented: $isSteamLoginPresented, onDismiss: {
                Task { await refreshSteamLoginState() }
            }) {
                SteamLoginSheet {}
            }
            .onAppear { Task { await refreshSteamLoginState() } }

        case .startup:
            settingsSection("启动") {
                settingsToggle("登录时启动", description: "登录 macOS 后自动打开 WallpaperMac。", binding: $launchAtLogin)
                HStack(spacing: 8) {
                    ThemeStatusDot(
                        color: LoginItemService.isEnabled ? AppTheme.Palette.applied : AppTheme.Palette.textTertiary,
                        size: 5
                    )
                    Text("系统登录项：\(LoginItemService.statusDescription)")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.danger)
                }
            }

            settingsSection("软件更新") {
                updateSectionContent
                ThemeHairline()
                settingsToggle(
                    "每天检查更新",
                    description: "每天最多检查一次 GitHub 发布，只在发现新版本时提示。",
                    binding: $autoCheckUpdates
                )
                ThemeHairline()
                settingsToggle(
                    "每天自动检查并安装更新",
                    description: "开启后每天定时检查；发现新版本会自动下载、校验并安装，应用将重启。关闭时只提示更新。",
                    binding: $autoInstallUpdates
                )
            }

        case .about:
            settingsSection("关于 WallpaperMac") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WallpaperMac")
                            .font(AppTheme.Typography.display(19))
                            .foregroundStyle(AppTheme.Palette.text)
                        Text(applicationVersionInfo.displayText)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                    Spacer()
                }
                ThemeHairline()
                Text("原生 macOS 壁纸引擎，使用 SwiftUI 与 AppKit 构建。项目以 GPL-3.0-or-later 发布。")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: "https://github.com/MrLLLLLLLLLL/WallpaperMac") {
                    Link("打开 GitHub 项目", destination: url)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.accent)
                }
            }
        }
    }

    @MainActor
    private func refreshSteamLoginState() async {
        steamLoggedIn = await steamLoginService.isLoggedIn
        if let name = await steamLoginService.savedUsername {
            steamUsername = name
        }
    }

    @MainActor
    private func steamLogout() async {
        await steamLoginService.logout()
        await refreshSteamLoginState()
        steamLoginError = nil
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeSectionHeader(title: title)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .themeInsetSurface()
        }
    }

    private func settingsToggle(
        _ title: String,
        description: String? = nil,
        binding: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.text)
                if let description {
                    Text(description)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AppTheme.Palette.accent)
        }
    }

    private func settingsPickerRow<Content: View>(
        _ title: String,
        description: String? = nil,
        @ViewBuilder picker: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.text)
                if let description {
                    Text(description)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            picker()
                .frame(width: 180)
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
        switch updateService.phase {
        case .idle, .checking:
            EmptyView()
        case .upToDate(let version):
            Text("当前已是最新版本（\(version)）")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let update):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("发现新版本 \(update.version)")
                        .font(.headline)
                    Spacer()
                    if let size = update.downloadSizeBytes {
                        Text("更新包大小 \(byteCountText(size))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                Text("下载并校验通过后会自动安装，应用将重启。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .fill(AppTheme.Palette.accent.opacity(0.08))
            )
        case .downloading(let update, let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("正在下载 \(update.version)")
                    .font(.headline)
                if let progress {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    HStack(spacing: 6) {
                        Text(downloadAmountText(progress))
                        if let speed = progress.bytesPerSecond, speed > 0 {
                            Text("·")
                            Text(speedText(speed))
                        }
                        Spacer()
                        if let fraction = progress.fractionCompleted {
                            Text("\(Int((fraction * 100).rounded()))%")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在连接下载服务器…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        case .failed(_, let message):
            HStack(alignment: .top) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.danger)
                Spacer()
                if updateService.canRetryDownload {
                    Button("重试更新") { updateService.retryDownload() }
                        .disabled(updateService.isBusy)
                }
            }
        }
    }

    private func applyHideHiddenHotKey(_ shortcut: HotKeyShortcut) {
        let result = GlobalHotKeyService.shared.updateShortcut(shortcut)
        switch result {
        case .success:
            // Only persist a shortcut Carbon actually accepted. A failed
            // attempt leaves both the active and stored shortcut unchanged.
            hideHiddenHotKey = shortcut
            shortcut.save(to: .standard, key: SettingsKey.hideHiddenHotKey)
            hotKeyMessage = "快捷键已更新。"
            isRecordingHotKey = false
        case .invalid, .conflict, .failure:
            hotKeyMessage = result.message
        }
    }

    private func byteCountText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func downloadAmountText(_ progress: UpdateDownloadProgress) -> String {
        if let total = progress.totalBytes, total > 0 {
            return "\(byteCountText(progress.bytesReceived)) / \(byteCountText(total))"
        }
        return byteCountText(progress.bytesReceived)
    }

    private func speedText(_ bytesPerSecond: Double) -> String {
        let rate = Int64(max(0, bytesPerSecond).rounded())
        return "\(byteCountText(rate))/s"
    }


    /// Always-visible prompt at the top of settings, so opening settings from
    /// the menu-bar update hint lands on the update without scrolling.
    @ViewBuilder
    private var updateBanner: some View {
        if case .available(let update) = updateService.phase {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(AppTheme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本 \(update.version)")
                        .font(.headline)
                    Text(updateBannerSubtitle(update))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("立即更新") { updateService.installUpdate(update) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(AppTheme.Palette.accent.opacity(0.10))
            ThemeHairline()
        }
    }

    private func updateBannerSubtitle(_ update: AvailableUpdate) -> String {
        if let size = update.downloadSizeBytes {
            return "更新包大小 \(byteCountText(size))，安装后应用将重启"
        }
        return "安装后应用将重启"
    }

    private func chooseLibraryFolder() {
        NotificationCenter.default.post(name: .wallpaperMacRequestLibraryMigration, object: nil)
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

    private var fitModeDescription: String {
        switch WallpaperFitMode(rawValue: fitMode) ?? .fill {
        case .fill:
            return "填充：保持比例并铺满屏幕，超出边缘的部分会裁剪。"
        case .fit:
            return "适应：保持比例并完整显示，空白区域保留背景色。"
        case .stretch:
            return "拉伸：分别调整宽度和高度，可能改变原始比例。"
        case .tile:
            return "平铺：按原始尺寸重复排列素材；仅适用于图片和视频，网页仍按视口排版。"
        }
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: .wallpaperMacSettingsChanged, object: nil)
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case appearance
    case playback
    case interaction
    case steam
    case startup
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .playback: return "播放"
        case .interaction: return "交互"
        case .steam: return "Steam 工坊"
        case .startup: return "启动与更新"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "壁纸库位置、导入方式与显示器入口"
        case .appearance: return "六套基于一天光线的界面主题"
        case .playback: return "静音、循环、适配与节能策略"
        case .interaction: return "网页壁纸点击与快捷键"
        case .steam: return "创意工坊下载账号"
        case .startup: return "登录项与软件更新"
        case .about: return "版本、构建与项目信息"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .appearance: return "circle.lefthalf.filled"
        case .playback: return "play.circle"
        case .interaction: return "cursorarrow.click"
        case .steam: return "gamecontroller"
        case .startup: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isSelected ? AppTheme.Palette.accent : Color.clear)
                    .frame(width: 2, height: 15)
                Image(systemName: category.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.Palette.accent : AppTheme.Palette.textSecondary)
                    .frame(width: 16)
                Text(category.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppTheme.Palette.text : AppTheme.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isSelected
                            ? AppTheme.Palette.accentWash
                            : (isHovering ? AppTheme.Palette.raised.opacity(0.55) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ThemePreviewCard: View {
    let theme: AppThemeDefinition
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ThemeMiniPreview(theme: theme)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(theme.name)
                            .font(AppTheme.Typography.display(15))
                            .foregroundStyle(theme.palette.text)
                        Text(theme.subtitle)
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.palette.accent)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? theme.palette.accent : theme.palette.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("切换到\(theme.name)")
    }
}

private struct ThemeMiniPreview: View {
    let theme: AppThemeDefinition

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.palette.canvas)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(theme.palette.accent)
                        .frame(width: 20, height: 2)
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(theme.palette.hairline)
                            .frame(width: 22, height: 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 40)
                .background(theme.palette.sidebar)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(theme.palette.text.opacity(0.7))
                            .frame(width: 48, height: 3)
                        Spacer(minLength: 0)
                        Circle()
                            .fill(theme.palette.accent)
                            .frame(width: 4, height: 4)
                    }
                    HStack(spacing: 5) {
                        miniCard
                        miniCard
                        miniCard
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
            }
        }
        .frame(height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.palette.hairline, lineWidth: 1)
        )
    }

    private var miniCard: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(theme.palette.panel)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(theme.palette.hairline, lineWidth: 0.5)
            )
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                    .fill(theme.palette.accent)
                    .frame(width: 10, height: 1.5)
                    .padding(4)
            }
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
    static let hideHiddenHotKey = "WallpaperMac.hideHiddenHotKey"
    static let launchAtLogin = "WallpaperMac.launchAtLogin"
    static let onboardingCompleted = "WallpaperMac.onboardingCompleted"
    static let autoCheckUpdates = "WallpaperMac.autoCheckUpdates"
    static let autoInstallUpdates = "WallpaperMac.autoInstallUpdates"
    static let appearanceTheme = "WallpaperMac.appearanceTheme"
    static let lastUpdateCheckDate = "WallpaperMac.lastUpdateCheckDate"
    static let lastAutomaticUpdateAttemptDate = "WallpaperMac.lastAutomaticUpdateAttemptDate"
    static let lockScreenSyncEnabled = "WallpaperMac.lockScreenSyncEnabled"
    static let originalDesktopImages = "WallpaperMac.originalDesktopImages"
    static let lastSyncedDesktopImages = "WallpaperMac.lastSyncedDesktopImages"
    static let automaticUpdateBlockedVersion = "WallpaperMac.automaticUpdateBlockedVersion"
    static let steamWorkshopAccount = "WallpaperMac.steamWorkshopAccount"
}

extension Notification.Name {
    static let wallpaperMacSettingsChanged = Notification.Name("WallpaperMacSettingsChanged")
    static let wallpaperMacRequestLibraryMigration = Notification.Name("WallpaperMacRequestLibraryMigration")
    static let wallpaperMacShowDisplaysOverview = Notification.Name("WallpaperMacShowDisplaysOverview")
    static let wallpaperMacShowSteamWorkshopBrowse = Notification.Name("WallpaperMacShowSteamWorkshopBrowse")
}
