# WallpaperMac 多队列管理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 WallpaperMac 从“每显示器一份队列”升级为可复用的命名队列库，并加入壁纸右键/批量管理和可独立管理的队列界面。

**Architecture:** 使用 `PlaybackQueueLibrary` 管理持久化命名队列，使用 `DisplayPlaybackBinding` 保存显示器活动队列、进度和显示器级覆盖。`WallpaperStore` 负责 JSON 和旧 `display-queues.json` 一次性迁移；`WallpaperManager` 负责绑定、调度、切换和删除壁纸后的恢复策略；SwiftUI 只通过 `MainViewModel` 调用这些服务。

**Tech Stack:** Swift 5.9, macOS 13+, SwiftUI, AppKit, Foundation JSON persistence, 当前自定义可执行测试目标。

---

### Task 1: 建立新队列模型和迁移测试

**Files:**
- Create: `Sources/WallpaperMacCore/PlaybackQueue.swift`
- Create: `Sources/WallpaperMacCore/DisplayPlaybackBinding.swift`
- Modify: `Sources/WallpaperMacCore/WallpaperStore.swift`
- Test: `Sources/WallpaperMacCoreTests/main.swift`

- [ ] 写测试覆盖默认队列约束、队列去重追加、自动排序切换为自定义、每队列单项时长覆盖和旧文件迁移。
- [ ] 运行 `swift run WallpaperMacCoreTests`，确认新增测试先失败。
- [ ] 实现可编码模型和归一化逻辑。
- [ ] 在 `WallpaperStore` 增加 `playbackQueues()`、`save(playbackQueues:)`、`displayPlaybackBindings()`、`save(displayPlaybackBindings:)`，首次读取旧格式时迁移并写新文件。
- [ ] 重新运行核心测试，确认通过。

### Task 2: 迁移 WallpaperManager 的队列存储和调度

**Files:**
- Modify: `Sources/WallpaperMac/WallpaperManager.swift`
- Modify: `Sources/WallpaperMacCore/PlaybackPolicy.swift`（仅必要时补充策略类型）
- Test: `Sources/WallpaperMacCoreTests/main.swift`

- [ ] 先加入队列库 API 的失败测试：创建/删除队列、绑定显示器、切换队列、显示器+队列覆盖、移除当前项后的回退。
- [ ] 让 `WallpaperManager` 发布 `[PlaybackQueue]`、`[String: DisplayPlaybackBinding]`，保留兼容的 `queue(for:)` 只读适配接口。
- [ ] 实现顺序/随机、循环/播放一次后停止、默认/单项时长、失败跳过和活动队列切换。
- [ ] 实现新显示器绑定默认队列、显示器重连恢复、删除活动队列切换默认队列。
- [ ] 运行核心测试和 `swift build`。

### Task 3: 接入 MainViewModel 的队列库操作

**Files:**
- Modify: `Sources/WallpaperMac/MainView.swift`
- Modify: `Sources/WallpaperMac/WallpaperManager.swift`

- [ ] 增加当前导航为队列库、当前队列、队列编辑状态和队列管理窗口状态。
- [ ] 加入批量右键动作：加队列、加分组、收藏、从队列移除、从分组移除、Finder、删除确认。
- [ ] 加入创建/编辑/删除/复制队列和显示器绑定操作。
- [ ] 删除壁纸时使用统一服务，保证队列引用、当前播放、默认队列回退和托管/外部文件规则一致。
- [ ] 运行 `swift build`，修复 SwiftUI 类型检查和 macOS 13 API 兼容问题。

### Task 4: 构建队列管理 UI 和右键菜单

**Files:**
- Modify: `Sources/WallpaperMac/MainView.swift`
- Create: `Sources/WallpaperMac/QueueManagementView.swift`（如拆分能降低类型检查复杂度）
- Modify: `Sources/WallpaperMac/MainWindowController.swift`（独立队列窗口）

- [ ] 在侧边栏加入“播放队列”。
- [ ] 实现队列列表、详情、规则编辑、拖拽排序和单项时长覆盖。
- [ ] 实现壁纸卡片单项/批量 context menu，并让“应用到显示器”只在单项时启用。
- [ ] 添加“打开独立队列管理窗口”入口。
- [ ] 加入空状态、撤销提示、删除确认和默认队列不可删除提示。
- [ ] 运行 `swift build` 并执行应用冒烟测试。

### Task 5: 回归验证和交付

**Files:**
- Modify: `README.md`（更新队列功能说明）
- Modify: `VERSION`（按项目版本规则递增）
- Modify: `plan.md`

- [ ] 运行 `swift run WallpaperMacCoreTests`。
- [ ] 运行 `./scripts/test-release.sh`。
- [ ] 运行 `./scripts/build-dmg.sh`、`hdiutil verify`、`codesign --verify --deep --strict`。
- [ ] 从 `/Applications/WallpaperMac.app` 启动并验证菜单栏、队列持久化和右键菜单入口。
- [ ] 检查 `git diff`、更新文档并提交一个清晰的功能提交。
