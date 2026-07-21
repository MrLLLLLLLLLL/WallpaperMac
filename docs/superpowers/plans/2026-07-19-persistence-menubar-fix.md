# WallpaperMac Persistence and Menu Bar Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 WallpaperMac 在重启后恢复壁纸库和显示器分配，并提供常驻菜单栏入口与控制动作。

**Architecture:** 在 Core 中加入可测试的库路径/书签持久化边界；在 AppKit 层由 AppDelegate 持有状态栏控制器和共享库模型。状态栏只通过动作闭包调用主窗口、设置和 WallpaperManager，不直接创建播放器窗口。

**Tech Stack:** Swift 5.9、SwiftUI、AppKit、Foundation、Swift Package Manager、macOS 13+。

---

### Task 1: 为壁纸库持久化增加可测试配置边界

**Files:**
- Create: `Sources/WallpaperMacCore/WallpaperLibraryConfiguration.swift`
- Modify: `Sources/WallpaperMacCoreTests/main.swift`

- [ ] 添加配置结构，包含 `libraryURL` 和 bookmark 数据，并支持保存/加载到指定配置目录。
- [ ] 测试将自定义库路径写入临时配置目录后，用新实例加载仍得到同一路径。
- [ ] 测试配置文件不存在时返回 nil，不创建空库记录。

### Task 2: 修复应用启动时的库恢复和路径切换

**Files:**
- Modify: `Sources/WallpaperMac/MainView.swift`
- Modify: `Sources/WallpaperMac/SettingsWindowController.swift`
- Modify: `Sources/WallpaperMacCore/WallpaperStore.swift`
- Modify: `Sources/WallpaperMacCoreTests/main.swift`

- [ ] 启动时优先读取持久化库配置，创建目录后再加载 metadata；不可访问时保留错误状态而不是静默回退到默认空目录。
- [ ] 设置窗口选择新目录时先创建并保存配置，成功后通知主模型切换 Store。
- [ ] managed copy 资源继续写入所选库目录的 `Assets/`，并补充重新实例化 Store 的回归测试。
- [ ] 启动恢复显示器分配时仅对存在且可用的记录尝试应用，missing 记录保留在列表中。

### Task 3: 添加 AppKit 菜单栏控制器

**Files:**
- Create: `Sources/WallpaperMac/StatusBarController.swift`
- Modify: `Sources/WallpaperMac/AppDelegate.swift`
- Modify: `Sources/WallpaperMac/WallpaperManager.swift`
- Modify: `Sources/WallpaperMac/MainView.swift`

- [ ] 创建 template `NSStatusItem` 并由 AppDelegate 强引用。
- [ ] 提供打开主窗口、暂停/继续、静音、打开壁纸库、打开设置、退出菜单。
- [ ] 为 WallpaperManager 增加全局动态壁纸暂停/继续和静音状态操作，菜单动作通过公开方法调用。
- [ ] 主窗口关闭后不销毁状态栏控制器；点击“打开 WallpaperMac”重新激活窗口。

### Task 4: 增加菜单栏与持久化回归验证

**Files:**
- Modify: `Sources/WallpaperMacCoreTests/main.swift`
- Modify: `scripts/test-release.sh`
- Modify: `README.md`

- [ ] 运行核心测试，确认 Store 重启模拟、配置恢复和现有 18 项行为均通过。
- [ ] 运行 Debug/Release 构建和既有 smoke test。
- [ ] 更新 README 说明默认库位置、菜单栏入口和故障恢复行为。
- [ ] 检查源码差异、签名和 DMG 构建。
