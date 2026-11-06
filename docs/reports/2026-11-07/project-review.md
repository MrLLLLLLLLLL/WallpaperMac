# WallpaperMac 当前项目整理与审查报告

- **报告日期**：2026-11-07
- **报告对象**：当前检出分支 `codex/web-url-wallpaper` 与其中未提交的 Codex 网页地址壁纸改动
- **审查方式**：读取完整 diff、交叉检查相关源码、查看 Git/版本状态、运行 Debug 构建、全部核心测试与完整发布测试
- **本轮原则**：只做整理、分析与验证，未修改项目源码或 Codex 未提交内容
- **报告性质**：记录当前分支状态，不代表远程 `main` 已包含这些功能

---

## 0. 结论摘要

当前项目是原生 macOS 壁纸管理应用，采用 **SwiftUI + AppKit、Swift Package Manager、AppKit 壁纸窗口、AVFoundation、WebKit 与内置 ffmpeg**。当前检出代码约 **13,445 行 Swift**，其中应用层 6,744 行、核心层 4,066 行、核心回归测试 2,635 行。

**Codex 的网页地址壁纸功能已完整接入主要链路**：

1. 主窗口“添加壁纸”与空库页面支持“导入网址”；
2. 通过 URL 校验和后台 Worker 写入壁纸库；
3. 以远程引用存储，不复制站点文件；
4. 使用 `WKWebView` 加载网址；
5. 支持失败提示、网页导航规则、新窗口链接交给默认浏览器；
6. 右键来源、检查器、缩略图标签与文档均已同步更新；
7. 增加远程网址导入/持久化/拒绝非法网址测试。

验证结果：

- `swift build`：**通过**。
- `WallpaperMacCoreTests`：**95/95 通过**。
- `scripts/test-release.sh`：**`ALL_RELEASE_TESTS_PASSED`**。
- 播放器矩阵、AV1 兼容、流式内存、网页交互、App 冒烟、签名/ZIP 包体检查：通过。

但当前版本仍不能直接视为已完成 0.2.8 发布准备：

- 工作区包含未提交改动；`VERSION` 被改为 `0.2.8`，但应用内开发回退版本仍为 `0.2.7`。
- 当前分支缺少本地另一个 `feat/0.2.8-update-experience` 分支中的更新器增强、多显示器阶段 1–4 和响应式标题栏改动。
- 两个分支都实现过远程网页壁纸，整合时会有功能/代码重叠，需按完整源码整合，不能直接简单合并。
- 自动测试验证了本地 HTML 网页和远程 URL 存储，但没有真正打开线上 HTTP/HTTPS 壁纸做端到端验收。
- 测试套件结束后运行中的 WallpaperMac 被退出；需自行启动即可恢复桌面，库路径配置已保持指向真实库。
- 未提交、未推送、未发布，也没有新增 GitHub Release。

---

## 1. 当前检出与分支状态

### 1.1 当前项目状态

| 项目 | 当前情况 |
|---|---|
| 当前目录 | `/Users/mrleft/MyProject/WallpaperMac` |
| 当前分支 | `codex/web-url-wallpaper` |
| HEAD | `aa7bdc3 chore: release 0.2.7` |
| 已发布远程主线 | `origin/main`：`77f0dd7 docs: add release checklist` |
| 仓库内 VERSION | `0.2.8`（Codex 的未提交修改） |
| GitHub 最新正式版本 | `v0.2.7` |
| 本轮源码提交 | 无 |
| 本轮 Git 推送/标签/Release | 无 |

### 1.2 Codex 改动规模

当前未提交改动共 **15 个文件，+323 / −36 行**：

- 数据与存储：`WallpaperItem.swift`、`WallpaperStore.swift`、`WallpaperStoreWorker.swift`。
- 应用与播放：`MainView.swift`、`WallpaperManager.swift`、`WallpaperResourceMetadataService.swift`、`WallpaperContextMenu.swift`。
- 测试：`WallpaperMacCoreTests/main.swift`。
- 文档与版本：`README.md`、`CHANGELOG.md`、`docs/README.md`、`docs/guides/quick-start.md`、`VERSION`。
- 构建与验证：`scripts/package-release.sh`、`scripts/test-release.sh`。

三个未跟踪 Markdown 文件未参与功能代码：`BugReport-2026-10-27.md`、`FixReview-2026-10-27.md`、`ProjectReport-2026-11-06.md`。

### 1.3 另一条本地 0.2.8 分支

| 分支 | 最新提交 | 当前主要工作 |
|---|---|---|
| `codex/web-url-wallpaper` | `aa7bdc3` | 当前工作区；网页地址壁纸 |
| `feat/0.2.8-update-experience` | `d8ba060` | 独立工作树；更新器、多显示器、响应式界面与另一个网页网址实现 |
| `main` | `77f0dd7` | 已发布的 0.2.7 主线 |

`feat/0.2.8-update-experience` 比当前分支多出的主要工作：

- 更新跳过、历史、失败恢复、跨启动续传与退出时保存断点；
- 多显示器稳定身份、档案与旧数据迁移；
- 热插拔防抖、attach/detach/geometry 差分处理；
- 每屏静音/循环/适配/暂停/网页交互设置；
- 主窗口窄宽度自适应。

**这些工作尚未包含在当前 Codex 分支。** 两分支都有 `WebWallpaperURL`、`importWebURL`、远程 WKWebView 加载和包体 ATS 改动，不能直接视作可重复合入的独立功能。

---

## 2. 项目结构与技术架构

### 2.1 SwiftPM Target

```text
Package.swift
├── WallpaperMac          应用可执行程序：SwiftUI + AppKit + WebKit
├── WallpaperMacCore      领域模型、存储、队列、更新、视频兼容
└── WallpaperMacCoreTests 无 XCTest 依赖的可执行核心回归测试
```

- `swift-tools-version: 5.9`。
- 最低支持：macOS 13。
- 本次实际验证：macOS 26.5.2、Apple M2、arm64、Swift 6.3.3。
- App Bundle 由 `scripts/package-release.sh` 创建，采用 ad-hoc 签名。
- App 内打包 ffmpeg 与动态库，用于不兼容 AVFoundation 的视频编码流式播放。

### 2.2 应用层

| 文件/模块 | 主要责任 |
|---|---|
| `ApplicationMain.swift` / `AppDelegate.swift` | NSApplication 生命周期、主窗口/设置、菜单栏、启动时更新检查 |
| `MainView.swift` | 主窗口三栏界面、库、导入、队列、检查器、网址导入弹窗 |
| `WallpaperManager.swift` | 壁纸窗口与播放器、队列计时、会话、暂停、热插拔、转场、网页代理 |
| `DisplayService.swift` | 当前 NSScreen 与显示器分配 |
| `SystemActivityMonitor.swift` | 电池、前台全屏应用、系统暂停 |
| `SettingsWindowController.swift` | 壁纸库、播放、交互、启动、更新与关于设置 |
| `UpdateService.swift` | 更新检查/下载/校验/安装生命周期 |
| `WallpaperVideoStreamController.swift` | ffmpeg 原始帧流式解码到 `AVSampleBufferDisplayLayer` |
| `WallpaperResourceMetadataService.swift` | 图片/视频元数据、视频缩略图 |
| `LoginItemService.swift` | macOS 登录项注册/注销 |
| `StatusBarController.swift` | 菜单栏控制与更新提示入口 |

### 2.3 核心层

| 模块 | 内容 |
|---|---|
| `WallpaperStore` / `WallpaperStoreWorker` | 库索引、导入/重定位/删除/可用性、后台串行持久化 |
| `WallpaperItem` / `WallpaperGroup` | 图片/视频/网页项目、分组、存储模式 |
| `PlaybackQueue` / `DisplayPlaybackBinding` | 队列、排序、随机、时长、推进策略、每屏进度 |
| `PlaybackPolicy` | 静音、循环、适配、暂停与网页交互 |
| `Update/` | GitHub Release 发现、下载、校验、签名、安装、恢复与版本比较 |
| `VideoContainerCompatibility` / `VideoPlaybackCompatibility` | HEVC 容器处理与 AV1/VP9 等兼容播放决策 |
| `ProcessRunner` | 外部进程超时、stderr 排空与终止处理 |
| `ThumbnailCache` | 缩略图缓存与路径/修改时间/大小键 |
| `DropURLCollector` | 拖放文件按原顺序聚合 |
| `UniquedDictionary` | 重复 ID 的防御处理 |

### 2.4 数据与播放流

```text
用户操作（导入 / 分配 / 队列 / 设置）
                │
                ▼
        LibraryViewModel（主线程）
          │              │
          │              ▼
          │       WallpaperManager（@MainActor）
          │         ├─ 图片：CALayer
          │         ├─ 视频：AVPlayer 或 ffmpeg 流式层
          │         └─ 网页：WKWebView（本地项目或在线网址）
          ▼
WallpaperStoreWorker（actor，后台串行 I/O）
          │
          ▼
WallpaperStore（JSON 索引、Assets、Thumbnails）
```

### 2.5 主要持久化文件

默认库：`~/Library/Application Support/WallpaperMac/Library`

```text
wallpapers.json                     壁纸项目与元数据
wallpaper-groups.json               分组
playback-queues.json                命名队列与策略
display-assignments.json            每屏壁纸分配
display-playback-bindings.json      每屏队列与进度
display-queues.json / .migrated     旧队列迁移来源与标记
Assets/                             托管素材副本
Thumbnails/                         生成的缩略图
```

其他配置：

```text
~/Library/Application Support/WallpaperMac/Configuration/
└── library-configuration.json      壁纸库路径与 security-scoped bookmark
```

当前检出分支仍是 0.2.7 风格的 `display-<CGDirectDisplayID>` 显示器键；稳定 UUID/序列号档案 `display-profiles.json` 只在另一分支实现。

---

## 3. Codex 网页地址壁纸实现审查

### 3.1 导入与界面

- `MainView.swift` 新增 `isWebURLImportPresented`。
- 添加壁纸按钮由单按钮改成菜单：“导入文件或文件夹”和“导入网址”。
- 空库页面提供同一菜单。
- 弹窗接受 HTTP/HTTPS 网址，禁止无效地址或带用户名密码的网址。
- 添加成功后选中新建项，并显示导入摘要；失败通过库错误提示展示。
- 首次启动介绍已改为“网页 / 网址”与在线网页说明。

**评价**：功能入口完整；空库入口与常规入口一致；错误和文案覆盖了离线、明文保存、脚本运行与可信来源风险。

### 3.2 核心数据与存储

- `WebWallpaperURL.isValid` 接受 `http` / `https`，要求非空 host，拒绝 URL 用户信息。
- `WallpaperStore.importWebURL` 创建 `type == .web`、`storageMode == .externalReference` 的 `WallpaperItem`。
- 项目写入 `wallpapers.json`，不复制站点资源到 `Assets/`。
- `WallpaperStoreWorker.importWebURL` 保持后台串行导入与现有索引持久化路径。
- 非文件 URL 可用性判断改为只验证远程网址的合法性，不以网络可达性决定项目是否存在。
- 本地 `importItem` 增加 `isFileURL` 防护；删除托管资源增加远程网址保护。
- 元数据采集对非文件 URL 直接跳过。

**评价**：数据语义一致，远程网址不会误走本地文件可用性/删除逻辑；导入成功不要求联网是合理行为。

### 3.3 网页播放

- `WallpaperContentView` 同时遵守 `WKNavigationDelegate` 和 `WKUIDelegate`。
- 本地网页仍使用 `loadFileURL(...allowingReadAccessTo:)`。
- 远程网址使用 `WKWebView.load(URLRequest(url:))`。
- 远程主框架/子资源导航只允许合法 HTTP/HTTPS；本地网页保持既有本地导航策略。
- 用户点击要求新窗口的链接时通过默认浏览器打开。
- 非取消类网络/导航失败显示提示，成功加载后隐藏。
- 播放器恢复后沿用原有静音、媒体播放/暂停和网页恢复策略。

**评价**：主要播放链路已经实现；导航规则与外部链接处理比单纯调用 `load` 更完整。

### 3.4 其他同步改动

- 右键来源操作对远程 URL 显示“在浏览器中打开”。
- 检查器显示“远程网址”“网址已保存，联网时加载”“远程网页”和实际网址。
- 卡片把本地网页标记为 HTML，把远程网址标记为 URL。
- README、文档中心、快速开始、CHANGELOG 均已新增远程网址说明。
- 打包 Info.plist 新增 `NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent = true`；发布测试会检查该键。
- 新增远程网址持久化与无效网址拒绝测试。

**总体结论**：功能在“导入 → 存储 → 界面 → 播放 → 删除 → 文档 → 构建验证”链路中较完整，未发现缺失到会使该功能完全无法使用的主链路缺口。

---

## 4. 现有整体功能

### 4.1 壁纸库与导入

- 本地图片、视频、`.html` 文件和完整 HTML 项目目录。
- 新增 HTTP/HTTPS 网页网址。
- 复制到应用库或引用本地原文件；远程网址只保存引用。
- 文件/文件夹拖放与文件选择；支持入口文件选择。
- 搜索、类型/状态筛选、排序、网格/列表、收藏、批量分组/队列操作。
- 文件失效检测、重新定位、重新扫描、索引与资源清理。
- 图片/视频分辨率、视频时长、文件大小与缩略图。
- 库与分组每页 20 项递增加载；后台串行存储 I/O。

### 4.2 播放与兼容

- 图片：`CALayer`，填充屏幕或完整显示。
- 视频：AVFoundation 播放，视频默认静音、可暂停/循环。
- HEVC `hev1`：必要时仅修容器标记，不重编码；不修改外部源文件。
- AV1/VP9 等：App 内 ffmpeg 解码后送入 `AVSampleBufferDisplayLayer`，不创建完整播放副本。
- 视频播放会话令牌防止旧回调推进错误队列。
- 看门狗：未知时长视频帧心跳与停滞窗口，硬顶保护，避免失败后队列永久停住。

### 4.3 队列与多显示器

- 多个命名队列、默认队列、每屏活动队列、每屏进度与播放状态。
- 顺序/随机、循环/播放一次、默认/单项时长、手动排序与删除占位。
- 转场：立即、淡入淡出、左右滑入、缩放淡入。
- 推进二选一：视频播完后切换 / 固定时长切换。
- 视频完成模式下，图片和网页自动用固定时长推进，避免队列停住。
- 显示器分配、队列绑定与断线恢复路径。

### 4.4 系统与更新

- 菜单栏打开主窗口/库/设置、播放暂停、全局静音、退出。
- 电池或全屏应用时暂停；网页点击效果；登录时启动。
- 壁纸库位置迁移与访问权限。
- 更新：GitHub Releases 检查、断点续传、SHA-256 流式校验、Ed25519 签名、安装重启、失败回滚。
- 发布脚本缺少更新签名私钥时 fail-closed。

注意：当前 Codex 分支没有另一分支的“跳过版本/历史/跨启动续传/退出协调”，不要将其当作当前已具备功能。

---

## 5. 测试、构建与实际结果

### 5.1 本轮已实际执行

| 项目 | 结果 |
|---|---|
| Debug `swift build` | 通过 |
| 核心回归测试 | 95/95 通过 |
| `git diff --check` | 通过 |
| 网页模板校验 | 通过 |
| Debug/Release 构建 | 通过 |
| App Bundle 与 ZIP 打包 | 通过 |
| 播放器运行时矩阵 | 图片/视频/本地网页通过 |
| 视频编解码运行时 | 通过 |
| 流式内存回归 | 通过 |
| 网页交互运行时 | 通过 |
| App 冒烟 | 通过 |
| Bundle/ffmpeg/Info.plist/签名/ZIP 检查 | 通过 |
| `scripts/test-release.sh` | `ALL_RELEASE_TESTS_PASSED` |

### 5.2 测试覆盖边界

**已验证**：

- 远程 URL 的校验、导入、索引保存、重新加载、可用性刷新、删除。
- 本地图片、视频、HTML 网页的真实壁纸窗口与播放。
- 视频兼容、网页点击、内存回归与更新发布包检查。
- ATS 键在打包后的 Info.plist 中存在。

**未验证**：

- 没有实际导入一个线上网页地址，确认页面成功加载、重定向与失败提示。
- 没有验证远程网址加入队列后按固定时长切换。
- 没有验证远程网页应用到两个显示器、断开重连与离线恢复。
- 没有对网站登录、视频自动播放、窗口打开与复杂交互做真实页面测试。
- 当前真实库没有远程网址项目，因此不存在存量 URL 兼容性实测。

因此，完整测试通过**不等于远程网页端到端验收已经完成**。

### 5.3 验证产生的副作用

- `test-release.sh` 重新构建了本地 App/ZIP，ZIP 以当前 `VERSION` 命名并带有 Ed25519 签名。
- 本轮没有执行发布步骤；`dist/` 文件仅是本地构建产物。
- 完整测试退出测试实例后，原 `/Applications/WallpaperMac.app` 进程也被结束；需要时可从“应用程序”重新启动。
- 测试后默认配置与 `library-configuration.json` 均仍指向真实用户库，未发现路径被临时测试库覆盖。

---

## 6. 风险、缺陷与后续处理建议

| 级别 | 事项 | 判断与建议 |
|---|---|---|
| 高 | 当前分支与 `feat/0.2.8-update-experience` 各自实现网页网址 | 两分支同名函数、存储方法、WKWebView 改动和 UI 均重叠。先做功能取舍与源码整合，保留每屏设置、拓扑、更新增强与当前更完整的网页 UI/外部链接处理 |
| 高 | 当前检出缺少另一分支的阶段 1–4 | 当前不是“0.2.8 全功能状态”；合并前不要据此判断多显示器或更新增强已完成 |
| 中 | `VERSION=0.2.8`，但两处 `fallbackVersion=0.2.7` | 应在发布准备阶段同步；需要区分“开发版本标识”与“正式发布版本”，不要以此状态直接对外发布 |
| 中 | 线上网页未做端到端验收 | 导入可信 HTTPS 测试页、验证断网提示、重定向、点击新窗口、静音与队列切换 |
| 中 | 远程网页的安全与隐私边界 | 页面会运行第三方脚本、访问网络资源；网址明文保存。现有提示正确，但应持续保留；可在后续增加网络内容与截图保护策略 |
| 中 | 远程网页可用性不代表联网可达 | 这是合理设计：离线不应删除记录；UI 已写“网址已保存，联网时加载”，应保持这一语义 |
| 中 | 远程网页无预览与元数据 | 当前只显示 URL 图标/文本，不做站点缩略图或标题抓取。这是功能限制而非 bug，但影响大量 URL 时的识别体验 |
| 中 | 无活动 CI | README 仍声称 GitHub Actions 会自动验证，但当前 `.github/workflows/ci.yml` 未被跟踪，历史上在 `b696301` 被移除。恢复 CI 或修正文档 |
| 低 | 当前分支的暂停与显示器键仍为 0.2.7 全局策略 | 当前分支没有按显示器暂停与稳定身份；应从另一分支整合，而不是重写一套 |
| 低 | 大文件维护成本 | `MainView.swift` 和 `WallpaperManager.swift` 均较大，功能继续增加前建议按导入、设置、队列、播放器拆分 |
| 低 | 单文件核心测试、无 XCTest | 当前能完整执行，但无法方便地按用例过滤、输出 CI 标准结果；可逐步迁移 |
| 低 | ad-hoc 签名、无 Developer ID/公证 | 与个人自用定位兼容；对外大范围分发需另行处理 Gatekeeper |

---

## 7. 建议的整合顺序

1. **确定 0.2.8 的唯一工作分支**：当前 Codex 分支承载网页网址功能，另一分支承载更新/多显示器，不宜各自发布。
2. **整合代码而不是重复实现**：保留当前 Codex 分支中更完整的远程网页 UI、错误提示与外部链接行为，同时纳入另一分支的每屏策略、显示器档案、更新历史/跨启动续传等。
3. **统一版本状态**：继续将未发布工作归入 0.2.8；同步应用内回退版本、CHANGELOG 与发布说明，不自动推送或发布。
4. **恢复测试环境的桌面**：重新启动 `/Applications/WallpaperMac.app`，确认实际库与双屏壁纸恢复。
5. **做真实网页与多显示器验收**：可信网址、离线、队列、双屏、重连、每屏设置与系统暂停。
6. **修正文档与 CI**：README 中队列开关描述与 CI 声明；恢复最小构建/测试工作流。
7. **再决定提交与发布**：本轮不修改代码、不提交，不触碰当前 Codex 未提交工作。

---

## 8. 当前项目状态速查

```text
已发布版本：          0.2.7
当前开发分支：        codex/web-url-wallpaper
当前 VERSION：        0.2.8（未提交）
Codex 改动：          15 文件，+323 / −36，未提交
当前核心测试：        95 通过
完整发布测试：        通过
线上网址真实验收：    尚未执行
0.2.8 另一分支工作：  当前分支未包含
本轮提交/推送/发布：  无
```

**综合结论**：网页地址壁纸的主要实现是完整、合理且通过现有自动化验证的；当前项目更需要的是“分支整合 + 线上网页真机验收 + 版本与文档一致性”，而不是重新设计或重写网页功能。
