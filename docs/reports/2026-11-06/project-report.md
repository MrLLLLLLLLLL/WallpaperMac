# WallpaperMac 项目详细报告

- **报告日期**：2026-11-06
- **报告范围**：仓库状态、分支与版本、源码架构、功能实现、测试与构建、发布状态、风险与技术债
- **分析环境**：macOS 26.5.2（25F84）、Apple M2、Swift 6.3.3、arm64
- **说明**：除特别标注外，源码路径均指 `feat/0.2.8-update-experience` 工作树内的文件；主检出 `main` 分支仍是 0.2.7，不包含 0.2.8 代码。

---

## 0. 结论摘要

WallpaperMac 是一个功能已经相当完整的原生 macOS 壁纸引擎：支持图片、视频、本地网页以及 0.2.8 新增的远程网址壁纸，具备多显示器独立分配、播放队列、稳定显示器身份、应用内自动更新与完整的发布校验链路。

当前质量状态良好：

- 51 个 Swift 文件、约 **16,201 行**代码（应用层 7,691 / 核心层 5,093 / 测试 3,417）。
- **122 项核心回归测试**全部通过。
- 完整发布套件（构建、运行时矩阵、编解码、内存、网页交互、冒烟、包体检查）通过。
- 最新 DMG 已构建、挂载、签名与版本校验通过。

当前主要事项：

1. 0.2.8 的功能已完成并提交在本地功能分支，但**尚未合并、推送或发布**。
2. 阶段 4（每屏独立设置）还没有做真实多显示器的全屏/电池/重连验收。
3. 本地 `dist/` 中存在以 **0.2.7 命名、但由 0.2.8 代码构建**的 zip/dmg，存在误上传到既有 0.2.7 Release 的流程风险。
4. README 与多显示器设计稿的状态说明已滞后。

---

## 1. 项目概况

| 项目 | 内容 |
|---|---|
| 名称 | WallpaperMac |
| 定位 | 面向 macOS 13+ 的本地图片、视频与 HTML 网页壁纸引擎 |
| 技术栈 | Swift 5.9+（实际使用 Swift 6.3.3 工具链）、SwiftUI + AppKit、Swift Package Manager |
| 平台 | macOS 13 Ventura 及以上；当前在 macOS 26.5.2 上验证 |
| 仓库 | `https://github.com/MrLLLLLLLLLL/WallpaperMac` |
| 许可证 | GPL-3.0-or-later |
| 当前发布版本 | **0.2.7**（2026-11-02 发布） |
| 仓库内 VERSION | `0.2.7` |
| 未发布工作 | 0.2.8（本地功能分支，累计 10 个提交） |
| 应用签名 | ad-hoc 签名；无 Developer ID / 公证（与项目定位一致） |
| 更新签名 | Ed25519 私钥位于仓库外的 `secrets/`，未纳入版本控制 |

项目自述为“以自用为目的的 vibecoding 项目”，不提供账户、云同步或在线素材市场；默认所有工作流围绕本地文件展开。0.2.8 新增的远程网址壁纸是用户主动输入的 HTTP/HTTPS 地址。

---

## 2. 仓库、分支与版本状态

### 2.1 分支

| 分支 | 提交 | 状态 |
|---|---|---|
| `main` | `77f0dd7 docs: add release checklist` | 与 `origin/main` 同步，对应已发布的 0.2.7 |
| `feat/0.2.8-update-experience` | `d8ba060 feat: add per-display playback settings and web URL wallpapers` | 位于 `.claude/worktrees/competent-nash-e52e3f` 工作树，比 main 多 10 个提交，未推送 |
| `claude/competent-nash-e52e3f` | `aa7bdc3 chore: release 0.2.7` | 旧发布分支，远端已删除 |

### 2.2 已发布版本

GitHub Release `v0.2.7` 已确认：

- 标题：`WallpaperMac 0.2.7`
- 发布时间：2026-11-02T17:17:07Z
- 非草稿、非预发布
- 资源：DMG、ZIP、ZIP 签名、SHA256SUMS，共 4 个

### 2.3 0.2.8 累计改动

`main..feat/0.2.8-update-experience`：**30 个文件，+3,585 / −191 行**。

| 提交 | 内容 |
|---|---|
| `5f7390e` | 更新器：跳过版本、更新历史、失败恢复 |
| `8208fb1` | 跨启动更新断点续传 |
| `9896917` | 修复库标题“视图”竖排 |
| `f340575` | 文档：发布需明确授权 |
| `0e30d92` | 库标题栏按窗口宽度自适应 |
| `e06f79c` | 多显示器状态模型设计稿 |
| `fb0808f` | 阶段 1：显示器身份与拓扑 reducer |
| `7a5effd` | 阶段 2：稳定显示器档案与旧数据迁移 |
| `9aa041f` | 阶段 3：差分热插拔与几何变化只更新窗口 |
| `d8ba060` | 阶段 4：每屏独立播放设置；网页网址壁纸 |

### 2.4 版本策略

用户已明确规定：

> 发布新版本只在明确要求时进行；未发布期间的所有新增、删除、修改都计入下一个版本，直到明确发布该版本。

当前状态：

- 已发布：0.2.7
- VERSION：0.2.7（未升级）
- 未发布改动：计入 0.2.8
- `UpdateService` 与 `SettingsWindowController` 的 `fallbackVersion` 仍为 `0.2.7`；正式发布 0.2.8 时必须同步更新
- `CHANGELOG.md` 已有 `[未发布]` 段落，但尚无 `docs/release-notes/0.2.8.md`

### 2.5 本地工作区

- 主检出根目录保留两个未跟踪的评审资料：`BugReport-2026-10-27.md`、`FixReview-2026-10-27.md`（不提交）。
- 功能分支工作树干净，无未提交改动。
- 本地 `dist/` 是构建产物目录，已被 `.gitignore` 排除。

---

## 3. 技术架构

### 3.1 包结构

```text
Package.swift
├── WallpaperMac          可执行应用（SwiftUI + AppKit）
├── WallpaperMacCore      领域模型、持久化、队列、多显示器、更新、视频兼容
└── WallpaperMacCoreTests 无 XCTest 依赖的可执行核心回归测试
```

- `swift-tools-version: 5.9`
- 最低系统：macOS 13
- 实际构建工具链：Swift 6.3.3

### 3.2 应用层（18 个文件，7,691 行）

| 文件 | 职责 |
|---|---|
| `ApplicationMain.swift` / `AppDelegate.swift` | NSApplication 生命周期、主窗口/设置窗口、菜单栏控制器、退出前保存更新断点 |
| `MainWindowController.swift` | 主窗口创建与最小尺寸约束 |
| `MainView.swift`（2,898 行） | 三栏主界面、壁纸库、导入、队列编辑、检查器、显示器播放设置、网页网址导入 |
| `WallpaperManager.swift`（2,105 行） | 播放核心：窗口/播放器生命周期、队列计时器、视频完成回调、热插拔、每屏策略、系统暂停 |
| `DisplayService.swift` / `DisplayIdentityProvider.swift` | 显示器列表与稳定身份采集（ColorSync UUID、厂商/型号/序列号、CGID、名称+分辨率） |
| `StatusBarController.swift` | 常驻菜单栏：打开窗口/库/设置、暂停、静音、更新提示、退出 |
| `SettingsWindowController.swift` | 壁纸库、显示器、播放、交互、快捷键、登录启动、软件更新、关于 |
| `UpdateService.swift` | 更新检查/下载/校验/安装生命周期、每日检查、跳过、历史、退出协调 |
| `WallpaperVideoStreamController.swift` | ffmpeg 解码帧 → `AVSampleBufferDisplayLayer` 的流式播放 |
| `WallpaperVideoCompatibilityService.swift` | HEVC `hev1` 兼容、旧播放缓存清理 |
| `WallpaperResourceMetadataService.swift` | 图片/视频元数据与缩略图 |
| `WallpaperLibraryAccess.swift` | 壁纸库路径访问封装 |
| `LoginItemService.swift` | `SMAppService` 登录项 |
| `SystemActivityMonitor.swift` | 电池状态与前台全屏应用所在显示器检测 |
| `QueueManagementView.swift` / `WallpaperContextMenu.swift` | 队列管理界面与资源右键菜单 |

### 3.3 核心层（32 个文件，5,093 行）

| 模块 | 主要类型 | 职责 |
|---|---|---|
| 壁纸库 | `WallpaperStore`、`WallpaperStoreWorker`、`WallpaperItem` | JSON 索引、导入/删除/重定位、可用性、缩略图、后台串行 I/O |
| 分组与队列 | `WallpaperGroup`、`PlaybackQueue`、`DisplayPlaybackQueue`、`DisplayPlaybackBinding` | 分组、命名队列、每显示器活动队列与进度 |
| 播放策略 | `PlaybackPolicy`、`DisplayPlaybackSettings` | 全局策略、每屏覆盖解析、暂停规则 |
| 多显示器 | `DisplayIdentity`、`DisplayProfile`、`DisplayTopologyReducer`、`DisplayProfileMigrator` | 稳定身份、档案、差分拓扑、旧数据迁移 |
| 更新 | `UpdateChecker`、`UpdateDownloader`、`ProgressDownload`、`UpdateArtifactVerifier`、`UpdateInstaller`、`UpdateSignature`、`UpdateResumeState`、`UpdateHistory`、`SemVer` | GitHub Releases 检查、断点续传、SHA-256、Ed25519、安装与回滚、历史 |
| 视频兼容 | `VideoContainerCompatibility`、`VideoPlaybackCompatibility`、`ProcessRunner` | `hev1` 容器修正、AV1/VP9 流式方案、子进程超时与管道处理 |
| 其他 | `ThumbnailCache`、`DropURLCollector`、`UniquedDictionary`、`WallpaperPreviewLayout`、`URLDirectory`、`WebMouseEventScript` | 缓存、拖放聚合、唯一字典、16:9 预览、网页点击脚本 |

### 3.4 运行时数据流

```text
SwiftUI 视图
   │ 用户操作
   ▼
LibraryViewModel ──► WallpaperStoreWorker（actor，串行文件 I/O）
   │                        │
   │                        ▼
   │                 WallpaperStore（JSON 索引 / Thumbnails / Assets）
   ▼
WallpaperManager（@MainActor）
   ├── WallpaperWindowController
   │      ├── 图片：CALayer
   │      ├── 视频：AVPlayerLayer 或 ffmpeg 流式层
   │      └── 网页：WKWebView（本地目录或远程 URL）
   ├── 队列计时器 / 硬顶计时器 / 暂停冻结快照
   ├── DisplayService → DisplayIdentity → DisplayTopologyReducer
   └── SystemActivityMonitor（电池 / 分屏全屏状态）

UpdateService
   └── UpdateChecker → UpdateDownloader → 校验（SHA-256 + Ed25519）→ UpdateInstaller
```

并发模型：

- UI 与播放控制集中在 `@MainActor`；
- 壁纸库文件操作通过 `WallpaperStoreWorker` actor 串行化；
- 视频解码在专用队列/子进程中完成，帧数据通过 `AVSampleBufferDisplayLayer` 请求驱动；
- 外部进程统一走 `ProcessRunner`，带超时与 stderr 排空；
- JSON 写入使用原子写，关键删除顺序为“先写索引、后删资源”。

### 3.5 数据结构与持久化

库目录（默认 `~/Library/Application Support/WallpaperMac/Library`）：

| 文件/目录 | 内容 |
|---|---|
| `wallpapers.json` | 壁纸项目、元数据、可用性、收藏、分组 |
| `wallpaper-groups.json` | 分组 |
| `playback-queues.json` | 命名队列与播放策略 |
| `display-playback-bindings.json` | 每显示器活动队列、进度、播放状态（旧格式，保留降级兼容） |
| `display-assignments.json` | 显示器壁纸分配（旧格式，保留降级兼容） |
| `display-profiles.json` | 0.2.8 稳定显示器档案（schema 2）：身份、分配、绑定、每屏设置、离线记录、未匹配旧记录 |
| `display-queues.json` | 旧版队列迁移来源 |
| `Assets/` | “复制到应用库”的资源副本 |
| `Thumbnails/` | 缩略图 |
| `Configuration/` | 壁纸库路径配置、更新断点 `update-resume.json`、更新历史 `update-history.json` |

### 3.6 多显示器状态模型

身份匹配优先级：

1. ColorSync `CGDisplayCreateUUIDFromDisplayID` 的 UUID；
2. 厂商号 + 型号 + 序列号；
3. 运行时 `CGDirectDisplayID`；
4. 本地化名称 + 像素分辨率；
5. 无匹配则创建新档案。

拓扑动作：

- `attach(profileID, identity, isNewProfile)`：恢复壁纸/队列；
- `detach(profileID)`：停止计时器、释放窗口、保留档案；
- `updateGeometry(profileID, geometry)`：只更新窗口 frame，不重启播放；
- `flagReview(profileIDs)`：同型号冲突时标记待确认。

实现要点：

- 屏幕通知 200 ms 防抖；
- 几何变化（分辨率/排列/缩放）不重建控制器，实测窗口 ID 保持不变；
- 档案文件为准，旧 assignment/binding 文件继续双写以支持降级；
- 0.2.8 每屏设置：静音、循环、适配方式、电池暂停、全屏暂停、网页交互；`nil` 跟随全局。

---

## 4. 功能清单

### 4.1 壁纸库与导入

- 支持图片（jpg/jpeg/png/gif/webp/heic/heif/tif/tiff）、视频（mp4/mov/m4v/webm/avi/mkv）、HTML 文件/目录。
- 目录导入优先识别 `index.html`，可选择入口文件。
- 两种存储策略：复制到应用库 / 引用原文件。
- 拖拽导入、文件选择、搜索、类型/状态筛选、排序、网格/列表、收藏、批量操作。
- 失效资源检测、重新定位、重新扫描。
- 元数据：格式、大小、分辨率、时长；视频优先内嵌封面，否则首帧。
- 16:9 横屏预览框；分页每页 20 项。
- 0.2.8 新增：导入 HTTP/HTTPS 网址作为网页壁纸；远程项目不写入 `Assets/`。

### 4.2 播放与渲染

- 图片：`CALayer`，按 `fill`/`fit` 适配。
- 视频：常规编码用 `AVPlayer`；AV1/VP9 等用内置 ffmpeg 流式解码，不生成完整播放副本。
- HEVC `hev1`：托管副本做容器标记修正，不重编码；外部引用不改源文件。
- 网页：本地 HTML 项目通过 `loadFileURL`，远程网址通过 `WKWebView.load`；可选点击交互层。
- 播放控制：播放/暂停、静音、循环、重新加载网页。
- 队列切换的播放会话令牌可拒绝旧回调，避免双跳。
- 视频看门狗：未知时长视频 60 秒帧心跳停滞窗口 + 4 小时硬顶；已知时长按视频时长估算。

### 4.3 播放队列

- 多个命名队列，默认队列受保护。
- 每块显示器独立选择活动队列。
- 顺序/随机、循环/播放一次、默认间隔、单项时长覆盖。
- 转场：立即切换、淡入淡出、向左/右滑入、缩放淡入。
- 切换时机二选一：
  - **视频播完后切换**：视频按实际结束推进；图片和网页自动回退固定时长；
  - **固定时长切换**：所有类型按设定时长推进。
- 旧布尔字段 `advanceAfterVideoCompletion` 自动迁移并继续写出，支持降级。
- 队列编辑保留删除占位与自定义顺序。
- 系统暂停期间冻结队列计时器，恢复后按剩余时间继续（0.2.8）。

### 4.4 多显示器

- 每屏独立壁纸、活动队列、进度、播放/暂停状态。
- 0.2.8：稳定身份、档案、热插拔差分处理、几何变化不重启播放。
- 0.2.8：每屏独立播放设置（主窗口显示器视图标题栏的滑杆入口）。
- 断开保留档案与队列进度；重连按档案恢复。
- 同型号冲突标记 `needsReview`；冲突确认界面留待阶段 5。

### 4.5 应用内更新

- 检查：GitHub Releases API + SemVer 比较；每日检查一次；后台发现更新只显示菜单栏徽标。
- 下载：URLSession 下载任务，实时速度/大小；弱网停滞检测、重试上限、断点续传；跨启动保存恢复数据（版本、URL、SHA-256、resume data）。
- 校验：完整落盘文件 SHA-256 流式比对 + Ed25519 签名（域分隔 `WallpaperMac-update-v1\n` + 摘要）。
- 安装：前置校验（标准 .app、非 App Translocation、可写安装位置、版本匹配）；ZIP 解压；detached 脚本等待父进程退出、备份 `.previous`、`ditto` 安装、清理 quarantine、重启；失败回滚。
- 体验：跳过版本、更新历史、按失败类型给出恢复建议、重试下载、打开发布页。
- 发布：缺少签名密钥时 fail-closed，本地开发需显式 `WALLPAPERMAC_ALLOW_UNSIGNED=1`。

### 4.6 菜单栏、设置与登录项

- 菜单栏：打开应用、打开壁纸库、设置、暂停/恢复动态壁纸、静音/取消静音、更新入口、退出。
- 设置：库路径、默认导入方式、显示器说明、播放策略、网页点击效果、快捷键占位、登录时启动、软件更新、关于。
- 登录项：`SMAppService.mainApp` 注册/注销，并显示系统批准状态。
- 关闭主窗口不退出应用。

---

## 5. 版本演进

| 版本 | 主题 |
|---|---|
| 0.2.4 | 壁纸库 I/O 移至后台 Worker；分组批量持久化；HEVC `hev1` 支持 |
| 0.2.5 | AV1/VP9 流式兼容、网页点击效果、焦点修复、视频循环与看门狗修复 |
| 0.2.6 | 应用内自动更新、SHA-256 + Ed25519 完整性链、队列看门狗；大量稳定性修复 |
| 0.2.7 | 弱网更新断点续传、更新菜单栏徽标、队列切换时机二选一、安装前完整复检 |
| 0.2.8（未发布） | 更新器跳过/历史/恢复/跨启动续传；每屏独立设置；多显示器稳定身份与热插拔；网页网址壁纸；界面宽度适配 |

0.2.7 发布说明记录的验证：核心测试 94 项、完整发布套件通过、签名 zip 产出。当前分支已增长到 122 项测试。

---

## 6. 测试与质量保障

### 6.1 核心测试

- 单文件可执行测试：`Sources/WallpaperMacCoreTests/main.swift`（3,417 行）。
- 当前 **122 项全部通过**。
- 覆盖领域：存储与迁移、元数据、分组、队列与推进模式、显示器身份/拓扑/档案迁移、播放策略覆盖、更新检查/校验/签名/续传/安装/历史、视频容器兼容、拖放、分页、布局、进程超时等。

示例（更新相关）：

- 断点续传与恢复后全量复检；
- 恢复后篡改字节/坏签名被拒绝；
- 安装脚本等待父进程并回滚；
- App Translocation / 裸二进制拒绝；
- 更新历史持久化与上限；
- 跳过版本的后台静默。

示例（多显示器）：

- UUID、序列号、运行时 ID、名称+尺寸四级匹配；
- 新显示器 attach、移除 detach、仅几何变化 updateGeometry；
- 同型号冲突 flagReview；
- 旧 assignment/binding 迁移与 unmatched 记录认领；
- 档案 round-trip 含每屏 settings。

### 6.2 发布套件

`scripts/test-release.sh` 依次执行：

1. 网页模板校验；
2. 核心测试；
3. Debug / Release 构建；
4. App Bundle 与 ZIP 打包（ad-hoc 签名）；
5. 播放器运行时矩阵（图片/视频/网页，窗口截图非黑校验、元数据/缩略图）；
6. 视频编解码兼容；
7. 流式播放内存回归；
8. 网页交互；
9. 应用冒烟；
10. Bundle 检查（ffmpeg、Info.plist、签名、版本）；
11. `git diff --check`。

### 6.3 最近验证结果

| 项目 | 结果 |
|---|---|
| `swift build` | 通过 |
| `WallpaperMacCoreTests` | 122/122 通过 |
| 播放器运行时矩阵 | 通过（image / video / web） |
| 完整发布套件（最终源码） | `ALL_RELEASE_TESTS_PASSED` |
| DMG 构建 | `hdiutil verify` VALID |
| DMG 挂载校验 | 版本 0.2.7、ad-hoc 签名有效、ATS 键存在 |
| 新功能二进制检查 | `slider.horizontal.3`、网页壁纸文案存在 |

### 6.4 测试缺口

- SwiftUI/AppKit 应用层没有 UI 单元测试；导入、设置、队列编辑、显示器设置弹窗主要靠运行时冒烟。
- 每屏设置的真实交互、电池/全屏暂停、计时器冻结恢复没有自动化覆盖。
- 多显示器阶段 4 尚未在真实双屏上验收（阶段 3 已做过分辨率切换与物理插拔实测）。
- 远程网页壁纸的网络失败、重定向、ATS 行为没有自动化测试。
- 无 XCTest；测试为单可执行文件，无法按用例过滤，CI 集成较弱。
- `.github/` 在工作流提交后被 `.gitignore` 排除并删除，当前仓库没有 CI 配置；README 仍声称有 GitHub Actions。

---

## 7. 构建与发布

### 7.1 脚本

| 脚本 | 用途 |
|---|---|
| `scripts/package-release.sh` | Release 构建、App Bundle、Info.plist、ad-hoc 签名 |
| `scripts/build-dmg.sh` | 调用打包脚本并生成 UDZO DMG，`hdiutil verify` |
| `scripts/build-release.sh` | 打包 + ZIP + SHA-256 + Ed25519 签名 + SHA256SUMS |
| `scripts/test-release.sh` | 完整本地发布验证 |
| `scripts/player-runtime-test.sh` | 播放器运行时矩阵 |
| `scripts/video-codec-runtime-test.sh` | 编解码运行时 |
| `scripts/video-stream-memory-regression.sh` | 流式内存回归 |
| `scripts/queue-memory-regression.sh` | 队列切换内存回归 |
| `scripts/web-wallpaper-interaction-test.sh` | 网页交互 |
| `scripts/smoke-app.sh` | 应用冒烟 |
| `scripts/update-artifact-smoke.sh` | 发布产物下载/校验冒烟 |
| `scripts/bundle-ffmpeg.sh` | 内置 ffmpeg 与依赖库 |
| `scripts/validate-web-wallpaper-template.sh` | 离线网页模板校验 |
| `scripts/update-signing-tool.swift` | Ed25519 签名/验签工具 |

### 7.2 签名与安全

- App：ad-hoc 签名，未做 Developer ID 与 Apple 公证；首次启动可能被 Gatekeeper 拦截，README 提供右键打开方式。
- 更新：Ed25519 私钥位于仓库外，公钥内嵌应用；签名消息为固定域前缀 + 文件 SHA-256。
- 发布脚本缺少私钥时 fail-closed。
- 安装脚本检查 App Translocation、标准 .app 结构、可写安装位置与版本一致性，失败回滚。
- 更新下载在续传后重新执行完整哈希与签名校验，不信任断点字节。

### 7.3 本地构建产物

工作树 `dist/`：

| 产物 | 说明 |
|---|---|
| `WallpaperMac.app` | 0.2.8 源码构建的 App Bundle（版本 0.2.7） |
| `WallpaperMac-v0.2.7-macOS.dmg` | 本次新建，18 MB，SHA-256 `3ffb82d35a1bbb65c87c076863e919055a63bd4e2b5355a7b03e7890db84cf6e` |
| `WallpaperMac-v0.2.7-macOS.zip` | 发布套件生成（0.2.8 代码、0.2.7 版本号） |
| `WallpaperMac-v0.2.7-macOS.zip.sig` | 上述 ZIP 的 Ed25519 签名 |
| `WallpaperMac-v0.2.7-SHA256SUMS.txt` | 对应校验文件 |

主检出 `dist/` 仍有 0.2.5 / 0.2.6 历史产物。

### 7.4 发布流程

`docs/release-checklist.md` 规定：

1. 升级 `VERSION`、更新 CHANGELOG、发布说明、`fallbackVersion`；
2. 核心测试 + 完整发布套件；
3. `build-dmg.sh` + `build-release.sh`；
4. 哈希/签名/DMG/冒烟校验；
5. 打标签、推送、`gh release create`；
6. `update-artifact-smoke.sh` 验证线上产物。

发布授权规则已写入检查清单：**只有用户明确要求发布某个版本时，才执行版本号、标签与 GitHub Release 步骤。**

---

## 8. 风险与技术债

| 级别 | 事项 | 影响 | 建议 |
|---|---|---|---|
| 高 | 本地 `dist/` 存在 0.2.7 命名的 zip/dmg，但内容来自 0.2.8 代码 | 若误上传到已有 0.2.7 Release，会在同版本号下静默替换字节；签名仍然有效，更难发现 | 不要上传；在发布 0.2.8 前删除或明确归档这些同名产物；发布前核对哈希 |
| 中 | README 停留在 0.2.5，并声称“不提供远程 URL 壁纸”、旧的队列开关描述、GitHub Actions CI | 与实际功能矛盾，误导用户与贡献者 | 发布 0.2.8 前更新 README 的功能、版本、队列与 CI 说明 |
| 中 | 多显示器设计稿头部仍写“设计稿，未实现，目标 0.3.0” | 与阶段 1–4 已实现的事实不符 | 更新状态与目标版本；保留 §13 进度 |
| 中 | 每屏“自定义”会把 6 个字段全部写成显式值；入口在主窗口标题栏而非设计稿的设置页 | 用户只改一项后，后续全局变化不再影响该屏；与设计意图不一致 | 决定产品语义：逐字段“跟随全局 / 覆盖”，并考虑迁移到设置页 |
| 中 | 阶段 5 未实现：离线档案管理、认领旧记录、忘记显示器、同型号冲突确认 | `needsReview` 只能持久化，无法在界面处理；孤儿档案不可管理 | 规划阶段 5；至少提供只读的离线档案列表 |
| 中 | 阶段 4 未做真实多显示器验收 | 全屏暂停、电池暂停、每屏设置、重连恢复的真实行为未知 | 双屏实测：全屏/电池/设置切换/断开重连/队列继续 |
| 中 | 0.2.8 仅在本地分支，未推送、未合并 | 工作只存在于单机工作树；误删工作树会丢失提交 | 验收后合并到 main 并推送；或至少推送功能分支 |
| 中 | 远程网页壁纸：无缩略图/元数据；依赖网络；ATS 放开 Web 内容任意加载 | 库中显示为空预览；离线不可用；可访问任意 HTTP(S) 主机（含 localhost） | 文档说明限制；可考虑加载失败缓存与更细的 ATS 策略 |
| 低 | `MainView.swift` 2,898 行、`WallpaperManager.swift` 2,105 行 | 维护与评审成本高 | 按视图/职责拆分文件 |
| 低 | 单文件 3,417 行测试、无 XCTest、无 CI | 无法按用例过滤；回归依赖本地运行 | 迁移 XCTest 或增加测试过滤；恢复 CI |
| 低 | ad-hoc 签名、无公证 | 首次启动 Gatekeeper 拦截；不适合无提示的大规模分发 | 若扩大分发，申请 Developer ID 并公证 |
| 低 | 更新私钥丢失/轮换 | 私钥丢失后无法再发可信更新；轮换需先用旧钥发布一次 | 离线备份密钥；记录轮换流程 |
| 低 | 旧显示器文件双写 | 长期维护两份格式 | 至少一个发布周期后移除旧文件写入 |
| 低 | 镜像显示器只保留一个活动会话 | 镜像内容不做差异处理（设计非目标） | 在文档中明确 |

---

## 9. 建议的下一步

1. **完成 0.2.8 真机验收**：双屏下验证每屏静音/循环/适配/网页交互、全屏与电池暂停、计时器冻结恢复、断开重连与队列进度。
2. **更新文档**：README 版本/功能/队列/CI 说明；多显示器设计稿状态；发布 0.2.8 时补 `docs/release-notes/0.2.8.md` 并同步 `fallbackVersion`。
3. **确定每屏设置交互**：逐字段跟随/覆盖，或明确“自定义即全量快照”；决定入口是否迁移到设置页。
4. **处理本地同名产物**：删除或重命名 0.2.7 命名的 0.2.8 构建，避免误上传。
5. **实现阶段 5**：离线档案、认领/忘记、同型号冲突确认。
6. **合并与推送**：验收通过后将 `feat/0.2.8-update-experience` 合并到 `main`，推送分支与标签。
7. **工程化**：拆分大文件、迁移 XCTest、恢复 CI（至少模板校验 + 构建 + 核心测试）。
8. **分发准备**（可选）：Developer ID 签名与公证；否则保持 README 的 Gatekeeper 说明。

---

## 附录 A：关键文件索引

```text
Sources/WallpaperMac/WallpaperManager.swift        播放核心 / 队列 / 热插拔 / 每屏策略
Sources/WallpaperMac/MainView.swift                主界面 / 导入 / 队列编辑 / 显示器设置
Sources/WallpaperMac/UpdateService.swift           更新生命周期
Sources/WallpaperMac/DisplayService.swift          显示器列表
Sources/WallpaperMac/DisplayIdentityProvider.swift 稳定身份采集
Sources/WallpaperMac/SystemActivityMonitor.swift   电池与分屏全屏检测

Sources/WallpaperMacCore/WallpaperStore.swift      壁纸库持久化
Sources/WallpaperMacCore/PlaybackQueue.swift       队列模型与推进模式
Sources/WallpaperMacCore/PlaybackPolicy.swift      全局策略与每屏解析
Sources/WallpaperMacCore/Display/DisplayIdentity.swift
Sources/WallpaperMacCore/Display/DisplayTopology.swift
Sources/WallpaperMacCore/Display/DisplayProfileMigration.swift
Sources/WallpaperMacCore/Update/*
Sources/WallpaperMacCoreTests/main.swift           122 项核心测试
```

## 附录 B：常用命令

```bash
# 构建与核心测试
swift build
swift run WallpaperMacCoreTests

# 完整发布验证（工作树内需指向主检出的签名密钥）
WALLPAPERMAC_UPDATE_SIGNING_KEY=/Users/mrleft/MyProject/WallpaperMac/secrets/WallpaperMac.update.key ./scripts/test-release.sh

# 生成 DMG
./scripts/build-dmg.sh

# 生成签名 ZIP 与校验文件
WALLPAPERMAC_UPDATE_SIGNING_KEY=/Users/mrleft/MyProject/WallpaperMac/secrets/WallpaperMac.update.key ./scripts/build-release.sh
```

## 附录 C：系统与依赖

- macOS 13+（构建与测试环境 macOS 26.5.2）
- Swift 5.9+（实际 Swift 6.3.3）
- 内置 ffmpeg 与动态库（由 `bundle-ffmpeg.sh` 打入 App Bundle）
- 更新签名私钥：仓库外 `secrets/WallpaperMac.update.key`（不提交）
- 许可证：GPL-3.0-or-later
