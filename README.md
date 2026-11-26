# WallpaperMac

WallpaperMac 是一个原生 macOS 壁纸引擎与壁纸库管理器，支持图片、视频、本地 HTML 项目和 HTTP/HTTPS 网页壁纸，并提供多显示器、播放队列、隐藏壁纸、主题、自动更新和锁屏图片同步。

开发版本：**0.2.17** · 最新发布版：**0.2.16** · 平台：**macOS 13+** · 构建：**Swift Package Manager** · 许可证：**GPL-3.0-or-later**

## 文档导航

- [快速安装与升级](#安装与升级)
- [第一次使用](#第一次使用)
- [壁纸库与文件结构](#壁纸库与文件结构)
- [播放、队列与多显示器](#播放队列与多显示器)
- [隐藏壁纸与快捷键](#隐藏壁纸与快捷键)
- [锁屏图片同步](#锁屏图片同步)
- [开发与测试](#开发与测试)
- [发布](#发布)
- [贡献与安全](#贡献与安全)

本地文档中心还提供：[快速开始](docs/guides/quick-start.md)、[网页模板指南](docs/guides/web-wallpaper-template.md)、[构建与发布手册](docs/development/build-and-release.md)、[发布检查清单](docs/release-checklist.md)。这些 `docs/` 内容按项目约定只保存在本地，不随公开仓库分发。

## 产品能力

| 领域 | 当前能力 |
| --- | --- |
| 素材导入 | 本地图片、视频、单个 `.html` 文件、完整 HTML 项目目录，以及 HTTP/HTTPS 网址。目录项目可选择入口，优先识别 `index.html`。 |
| 播放 | 图片使用静态图层；视频使用 `AVPlayer`，AV1/VP9 等不兼容编码使用内置 ffmpeg 流式解码；网页使用 `WKWebView`。视频和网页默认静音。HEVC `hev1` MP4 的托管副本可将容器标记改为 `hvc1`（不重编码），外部源文件不改写。 |
| 壁纸库 | 搜索、类型/状态筛选、排序、网格/列表、分页、收藏、批量操作、分组、失效资源检查、缩略图与元数据补全。 |
| 存储 | “复制到应用库”或“引用原文件”。每个 managed 壁纸拥有独立 UUID 资源目录，外部引用只记录路径。 |
| 队列 | 多个命名队列、默认队列保护、顺序/随机、循环/播放一次、固定时长或视频播完切换、单项时长、转场。 |
| 多显示器 | 每块屏幕独立固定壁纸、队列、默认/隐藏槽位与进度；稳定显示器身份和热插拔恢复。 |
| 隐藏壁纸 | 密码保护应用内可见性，默认关闭显示；混合队列自动跳过不可见项。密码不加密文件。 |
| 界面 | 六个“一天光线”主题、三栏素材库、显示器总览/详情、队列工作区、设置窗口和常驻菜单栏。 |
| 系统集成 | 自定义隐藏快捷键、登录时启动、电池/全屏/睡眠/锁屏暂停、每日更新检查、可选自动安装、可选锁屏图片同步。 |

## 安装与升级

### 使用 DMG

1. 下载 `WallpaperMac-v<版本>-macOS.dmg`。
2. 打开 DMG，将 `WallpaperMac.app` 拖到 `Applications`。
3. 从“应用程序”启动，首次确认壁纸库位置，然后导入素材。

当前打包脚本使用 **ad-hoc 签名**，没有 Developer ID 或 Apple 公证。若 Gatekeeper 阻止首次启动，在 Finder 中按住 Control 单击应用，选择“打开”并确认。面向公众正式分发前，维护者仍需完成 Developer ID 签名和公证。

### 从旧版本升级

- **0.2.8–0.2.13**：这批版本的安装器会拒绝自己的临时交换名，无法通过应用内自动更新到达新版本。请下载最新 DMG（至少 0.2.15），手动覆盖安装一次；之后可恢复自动更新。
- **0.2.14**：队列和分配状态存在持久化缺陷，请尽快升级到 0.2.15 或更高版本。
- 其他较新版本可直接使用应用内更新，或按上面的 DMG 步骤覆盖安装。

## 第一次使用

### 1. 选择壁纸库

默认位置：

```text
~/Library/Application Support/WallpaperMac/Library
```

请选择持久、可读写的本地目录，不要使用 `/tmp`、仓库目录或会被系统清理的位置。可以在“设置 → 通用 → 壁纸库”更换或迁移。

### 2. 导入素材

把文件或目录拖入主窗口，或点击“添加壁纸”。远程网页通过“添加壁纸 → 导入网址”添加，仅接受 HTTP/HTTPS；网址只保存引用，不复制站点资源。

| 导入方式 | 行为 | 删除应用内条目时 |
| --- | --- | --- |
| **复制到应用库** (`managedCopy`) | 将资源复制到 `Assets/{UUID}/`，原文件之后可以移动或删除。 | 删除托管副本和索引记录。 |
| **引用原文件** (`externalReference`) | 只保存原始路径，不复制资源，适合 Finder/其他工具继续管理素材。 | 只删除索引记录，不删除原文件。 |

网页目录导入时需要选择 HTML 入口；单个 HTML 文件只复制该文件，不会隐式复制父目录。网页建议使用离线相对路径，也可以使用仓库的 `Templates/SimpleWebWallpaper` 验证。

### 3. 应用到显示器

在素材库选择壁纸，在右侧检查器查看固定 16:9 预览、资源信息和维护操作，然后选择目标显示器并应用。每块显示器可以使用不同壁纸或队列。

菜单栏可以打开主窗口、暂停/恢复动态壁纸、静音、关闭隐藏壁纸、打开壁纸库、打开设置和退出。关闭主窗口不会退出应用。

## 壁纸库与文件结构

库目录由应用维护，典型结构如下：

```text
Library/
├── wallpapers.json                  # 主索引：类型、来源、隐藏、元数据、缩略图等
├── wallpapers.json.bak              # 主索引备份，用于丢失后的恢复
├── wallpapers.json.recover          # 可选：恢复后的资源对账标记
├── playback-queues.json             # 命名队列与播放策略
├── display-playback-bindings.json   # 每屏队列槽位、进度和播放状态
├── display-assignments.json         # 固定壁纸分配及旧版兼容数据
├── display-profiles.json            # 稳定显示器身份和配置档案
├── wallpaper-groups.json            # 可选：自定义分组
├── display-queues.migrated          # 旧队列迁移完成标记
├── hidden-wallpapers-lock.json      # 隐藏密码摘要，不含明文密码
├── Assets/                          # managedCopy 资源
│   └── {UUID}/                      # 每个壁纸独立目录
│       └── {原始文件名或项目目录}
└── Thumbnails/                      # 应用生成的缩略图
```

### 索引与恢复

`wallpapers.json` 是主索引，`.bak` 是随成功保存更新的备份。索引丢失但素材目录非空时会尝试恢复；恢复标记未清除前不会执行孤儿清理，backup-only 库也不会被迁移过程凭空生成主索引。

`Assets/{UUID}/{原始文件名}` 是当前结构，旧平铺布局会在加载时自动迁移。主索引和 `.bak` 中的库内路径会一起更新，外部引用与远程 URL 不改写。应用托管缩略图随库迁移，旧的 `VideoProxies/` 按兼容策略清理。

外部引用不是资源复制。移动原文件、拔出磁盘或权限变化会使条目标记为失效；重新挂载、恢复路径或使用应用内重新定位即可。若希望应用独立保存素材，导入时选择“复制到应用库”。

详细的字段、迁移事务、备份恢复和完整快照写盘协议见 [存储与恢复协议](docs/development/storage-and-recovery.md)。

## 播放、队列与多显示器

### 队列规则

- 队列成员可增删、拖拽排序、设置单项时长。
- 播放方式支持顺序和随机；随机模式暂不提供“播放一轮后停止”，该选项会禁用并说明。
- “视频播完后切换”只对视频使用完成事件，图片/网页按固定时长推进；“固定时长切换”适用于所有类型。
- 手动暂停不会取消队列的启用状态；系统电池、全屏、睡眠或锁屏挂起也不会改写保存的用户播放意图。
- 视频完成队列有帧心跳 watchdog 和不可延长的硬上限，避免卡死时永不推进。
- 删除正在使用的队列会回退到默认队列并清理旧呈现；隐藏模式槽位不匹配时保持空白，不播放另一种队列。

### 多显示器

`DisplayIdentity` 优先使用 ColorSync UUID，配合序列号、型号和几何信息在重启、换接口或 ID 变化后匹配合适的档案。热插拔按屏幕分别决定保持、更新尺寸、恢复或断开，不会无谓重建其他屏幕的播放器。

## 隐藏壁纸与快捷键

隐藏壁纸默认不出现在素材库、队列和播放候选中。首次使用需要设置密码；重新显示需要密码，关闭显示不需要密码。菜单栏或全局快捷键都可以立即重新隐藏。

默认快捷键为 **⌃⌥H**。在“设置 → 交互 → 快捷键”可以录制新组合或恢复默认：

- 组合必须含至少一个 `⌃`、`⌥` 或 `⌘` 修饰键。
- 系统符号快捷键会先预检，应用保留组合会被拒绝，注册失败会保留旧组合与偏好。
- 状态栏菜单同步当前组合；保存但暂不可注册的组合会在设置中显示原因。
- 录制只使用应用内事件监视，不需要辅助功能权限。

**检测边界：** macOS 普通全局热键非独占，无法枚举所有第三方应用的占用；如果出现双重响应，请更换组合。

隐藏仅是应用内可见性控制，不是加密：文件、缩略图和索引仍可被拥有文件系统权限的人读取。项目不提供密码找回。

## 锁屏图片同步

“设置 → 交互 → 锁屏壁纸 → 同步当前壁纸到锁屏”默认关闭。开启后，每次应用壁纸或队列切换，会把当前壁纸的静态预览写入对应 `NSScreen` 的系统桌面图片：

- 图片：优先使用原始图片，源文件不可用时使用已有缩略图。
- 视频：使用已生成的缩略图，缺少时尝试补全。
- 网页：使用当前 `WKWebView` 页面快照。

同步使用公开的 `NSWorkspace.setDesktopImageURL`，并做节流和重复路径检查，避免快速队列切换时频繁写入。快照保存在 `~/Library/Application Support/WallpaperMac/LockScreen/`，位于壁纸库之外。关闭开关或更换壁纸不会自动删除已有快照；如果页面包含敏感内容，请在不再使用后手动清理该目录。

退出应用时，会尝试把同步前记录的原桌面图片恢复到每个屏幕；这个恢复只针对曾经同步过的屏幕，且依赖原图片文件仍存在。更换开关本身只停止后续写入，不会恢复原图。

在壁纸详情的“锁屏预览”中，可以查看当前壁纸的锁屏图片，点击“替换锁屏图片…”上传自定义图片；自定义覆盖图保存在壁纸库的 `LockScreen/{UUID}.png`，会随库迁移，并可随时“恢复自动预览”。

**系统边界：** AppKit 设置的是每个屏幕的系统桌面图片，是否同时用于锁屏由 macOS 决定；不提供独立锁屏图片 API，也不修改私有锁屏缓存或 FileVault/preboot 登录界面。关闭开关只停止后续同步，不会替换成其他图片或恢复原图片。

## 设置与自动更新

“设置 → 启动与更新 → 软件更新”提供：

- **每天检查更新**：默认开启。启动时、常驻期间和唤醒后按 24 小时间隔检查 GitHub Release，发现新版本时提示。
- **每天自动检查并安装更新**：默认关闭。开启后，发现新版本会自动下载、SHA-256 校验、Ed25519 验签、安装并重启；开启它会同时开启每日检查。

每日检查与自动安装分别控制，关闭每日检查不会自动安装。成功检查和自动尝试时间共同限流；确定性失败的同一版本不自动重装，手动“检查更新”“立即更新”“重试更新”仍可用。手动检查不会未经操作自动安装。

应用使用 ad-hoc bundle 签名，但更新包还使用独立的 Ed25519 签名、SHA-256 清单、安装锁、原子交换、健康握手和失败回滚。

## 界面与主题

主窗口按对象组织为素材库、显示器和队列工作区，提供六套主题：深夜暗房、午夜、晨光、蓝调时刻、正午、余烬。主题保存在本机并应用于主窗口、检查器、队列、设置和引导；壁纸窗口保持系统外观。

网格卡片固定 190pt，预览统一 16:9，分页按视口容量计算；窗口最小宽度为 1242pt。

## 开发与测试

### 环境

- macOS 13+
- 兼容的 Xcode / Command Line Tools 和 Swift 工具链
- 构建发布 App 时，默认需要 `/opt/homebrew/bin/ffmpeg`，可用 `WALLPAPERMAC_FFMPEG_SOURCE` 覆盖。

### 日常命令

```bash
swift build
swift run WallpaperMacCoreTests
./scripts/validate-web-wallpaper-template.sh
swift run WallpaperMac

# 生成可启动的 App Bundle
./scripts/package-release.sh
open dist/WallpaperMac.app
```

核心测试是 `WallpaperMacCoreTests` 可执行 target，不使用 XCTest；新增核心行为应在 `Sources/WallpaperMacCoreTests/main.swift` 添加实现并注册到测试数组。

### 验证层级

- GitHub Actions：模板校验、`swift build`、核心测试、空白检查。
- 本地发布闸门：核心测试、Debug/Release 构建、App/ZIP/DMG、签名与清单、同源一致性、播放器/适配/隐藏/视频/队列/网页/更新事务矩阵、内存回归和 App 冒烟。
- 真实桌面验证需要图形会话、显示器、ffmpeg、录屏和辅助功能权限；CI 不覆盖这些场景。

## 发布

只有维护者明确要求时才发版。版本载体必须一致：`VERSION`、`ApplicationVersionInfo.developmentFallbackVersion`、README 当前版本、`CHANGELOG.md` 和 `docs/release-notes/<version>.md`。

```bash
# 本地完整发布闸门（worktree 中请将两个变量指向主 checkout 的 secrets/）
export WALLPAPERMAC_UPDATE_SIGNING_KEY="$PWD/secrets/WallpaperMac.update.key"
export WALLPAPERMAC_UPDATE_SIGNING_PUBLIC_KEY="$PWD/secrets/WallpaperMac.update.key.pub"
./scripts/test-release.sh

# 生成同源 ZIP、DMG、.sig 和 SHA256SUMS
./scripts/build-release.sh

# 打标签、推送、创建 Release，并校验线上产物
./scripts/publish-release.sh --yes
```

签名私钥位于 gitignored 的 `secrets/`，不得提交。worktree 中运行发布测试时，用 `WALLPAPERMAC_UPDATE_SIGNING_KEY` 指向主 checkout 的私钥。`dist/` 和 `.build/` 是可再生目录，不提交 Git。

## 项目结构

```text
Sources/
├── WallpaperMac/             # SwiftUI/AppKit 应用、播放器、设置和系统集成
├── WallpaperMacCore/         # 模型、JSON 存储、队列、布局、更新与纯策略
└── WallpaperMacCoreTests/    # 可执行核心回归测试
scripts/                      # 构建、签名、发布和真实运行时验证
Templates/SimpleWebWallpaper/ # 离线网页模板
Assets/                       # 应用图标与品牌资源
```

## 贡献与安全

- [贡献指南](CONTRIBUTING.md)：代码边界、测试要求、PR 与发布流程。
- [安全政策](SECURITY.md)：私密报告渠道、资源/隐藏/更新/锁屏安全边界。
- [更新记录](CHANGELOG.md)：按版本记录用户可见变化。

使用本地或在线网页壁纸前，请只添加你信任的内容。远程网页会执行其脚本并访问网络，网址以明文保存在索引中，不要使用含敏感令牌的 URL。

本项目采用 [GPL-3.0-or-later](LICENSE)。
