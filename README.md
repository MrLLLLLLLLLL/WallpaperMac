# WallpaperMac

> 面向 macOS 13+ 的本地图片、视频与 HTML 网页壁纸引擎。

WallpaperMac 是一款使用 **SwiftUI + AppKit** 构建的原生 macOS 壁纸管理工具。它将本地图片、视频和本地 HTML 项目统一纳入壁纸库，支持多显示器独立分配、播放队列、分组、菜单栏控制和可迁移的壁纸库存储位置。

当前版本：**0.2.2** · 目标平台：**macOS 13+** · 构建方式：**Swift Package Manager**

> **项目说明：**这是一个以自用为目的的 vibecoding 项目，如果有什么问题欢迎提出。

> 本项目不提供远程 URL 壁纸、账户、云同步、在线素材市场或虚构演示资源。所有工作流围绕用户本地文件展开。

## 功能概览

| 领域 | 已实现能力 |
| --- | --- |
| 素材类型 | 导入本地图片、视频、`.html` 文件和本地 HTML 项目目录；目录导入优先识别 `index.html`。 |
| 壁纸库 | 支持自定义库位置、拖拽导入、文件选择、搜索、类型/状态筛选、排序、网格/列表、收藏、批量操作和失效资源检查。 |
| 存储策略 | 可选择“复制到应用库”或“引用原文件”；外部引用删除时只移除记录，不会删除用户原文件。 |
| 资源信息 | 显示格式、文件大小、图片/视频分辨率、视频时长和来源路径；视频优先使用内嵌封面，无封面时提取首帧。 |
| 资源预览 | 卡片与检查器统一使用固定 **16:9 横屏预览框**；竖屏或其他比例资源会填充裁剪展示，不会撑高界面。 |
| 多显示器 | 每块显示器可独立设置壁纸与活动队列；显示器断开后保留记录并提供恢复路径。 |
| 队列与分组 | 多个命名队列、默认队列保护、每显示器独立活动队列、顺序/随机、循环/播放一次、默认与单项时长、转场、视频结束后切换下一项。 |
| 播放器 | 图片窗口、`AVPlayer` 视频窗口、`WKWebView` 本地网页窗口；视频和网页默认静音，支持播放、暂停、静音、循环与网页重新加载。 |
| 菜单栏 | 常驻 WallpaperMac 图标，可打开窗口、暂停/恢复动态壁纸、静音/取消静音、打开壁纸库、打开设置或退出应用。 |
| 性能 | 壁纸库和分组以每页 48 项递增加载；队列切换释放前一播放器资源，降低长期切换时内存持续增长的风险。 |
| 设置与系统策略 | 可配置壁纸库路径、默认导入方式、静音/循环、适配方式、电池与全屏优化、登录时启动和快捷键状态。 |

## 界面与工作流

主窗口采用原生 macOS 深色三栏布局：

```text
┌───────────────┬────────────────────────────────────────┬─────────────────────┐
│ 左侧导航      │ 中央壁纸库                              │ 右侧检查器          │
│               │                                        │                     │
│ • 全部壁纸    │ 搜索 / 筛选 / 排序 / 网格或列表视图     │ 16:9 资源预览      │
│ • 图片        │                                        │ 资源信息            │
│ • 视频        │ 分页资源卡片或列表                     │ 显示器分配          │
│ • 网页        │ 右键：队列 / 分组 / 收藏 / Finder      │ 播放控制与维护操作  │
│ • 收藏/最近   │                                        │                     │
│ • 分组/显示器 │                                        │                     │
└───────────────┴────────────────────────────────────────┴─────────────────────┘
```

完整的本地设计规范、页面蓝图和实现契约在 [`docs/design/`](docs/design/README.md) 中维护。当前仓库不放置伪造截图或演示素材；首次启动时通过干净的空状态引导导入真实本地资源。

## 快速开始

### 安装预构建 App

如果你已获得项目发布的 DMG：

1. 打开 `WallpaperMac-v<version>-macOS.dmg`。
2. 将 `WallpaperMac.app` 拖到 `Applications`。
3. 从“应用程序”启动 WallpaperMac。
4. 首次启动时确认壁纸库位置，然后拖入图片、视频或本地 HTML 项目。

本地打包脚本使用 ad-hoc 签名。若 Gatekeeper 阻止首次启动，可在 Finder 中按住 Control 单击应用、选择“打开”，然后确认。对外正式分发前，应完成 Developer ID 签名与 Apple 公证。

### 从源码构建

```bash
git clone <你的 GitHub 仓库地址>
cd WallpaperMac

# 编译并运行核心回归测试
swift build
swift run WallpaperMacCoreTests

# 直接以开发方式运行
swift run WallpaperMac

# 生成可启动的 App Bundle
./scripts/package-release.sh
open dist/WallpaperMac.app
```

要求：macOS 13+、已安装兼容的 Xcode 或 Command Line Tools。更多步骤见 [构建、验证与发布指南](docs/development/build-and-release.md)。

## 首次启动与壁纸库

默认壁纸库目录：

```text
~/Library/Application Support/WallpaperMac/Library
```

该目录保存索引、显示器分配、分组、播放队列、缩略图，以及“复制到应用库”模式下的资源副本。请将它放在持久化、可读写的本地位置；不要使用临时目录、仓库工作目录或会在重启/清理后消失的位置。

可在“设置 → 壁纸库”中更换位置。移动原文件或外接磁盘未挂载时，“引用原文件”的项目会显示为失效，需要通过应用内维护操作重新定位；“复制到应用库”的副本不依赖原文件位置。

### 持久化数据

库目录中包含以下由应用维护的本地 JSON 索引和资源目录：

```text
wallpapers.json                    # 壁纸项目与元数据
playback-queues.json               # 命名队列与队列播放策略
display-playback-bindings.json     # 每显示器活动队列、进度与播放状态
display-assignments.json           # 显示器壁纸分配
wallpaper-groups.json              # 分组
display-queues.json                # 旧版本队列数据的迁移来源
Assets/                            # “复制到应用库”的资源副本
Thumbnails/                        # 生成的缩略图
```

应用还会在 `~/Library/Application Support/WallpaperMac/Configuration/` 保存壁纸库位置配置。旧版索引缺少新增字段时会使用兼容默认值读取；不要手工编辑 JSON，除非你已备份壁纸库并清楚数据格式的影响。

### 两种导入策略

| 策略 | 适合场景 | 删除 WallpaperMac 中的项目时 |
| --- | --- | --- |
| **复制到应用库** | 希望素材由 WallpaperMac 独立管理，原文件可能会移动或清理。 | 删除应用库托管副本和索引记录。 |
| **引用原文件** | 希望节约磁盘并继续由 Finder/其他工具管理素材。 | 只删除索引记录，绝不删除原始文件。 |

## 使用壁纸

### 导入图片、视频或网页项目

- 将文件或目录直接拖进主窗口，或使用“导入壁纸”。
- 网页壁纸可以是单个 `.html` 文件，也可以是一个完整本地 HTML 项目目录；导入目录时选择入口文件，通常是 `index.html`。
- 导入后在检查器查看预览和元数据，再将其应用到指定显示器。

视频与网页默认静音，避免在桌面环境意外播放声音。网页项目应使用离线相对路径，不依赖 CDN、远程脚本或在线图片。

### 管理资源

在壁纸卡片或列表项上右键，可进行：

- 添加到一个或多个播放队列；
- 添加到分组；
- 应用到指定显示器；
- 收藏、在 Finder 中显示、从队列移除或删除；
- 对多选资源执行相同的批量操作。

资源信息检查器显示图片/视频分辨率、视频时长、格式、文件大小和来源路径。所有资源在 UI 中以 16:9 横屏框呈现；这仅影响预览，不会裁剪或改写原始素材。

### 播放队列与多显示器

WallpaperMac 使用“**队列库 + 每个显示器一个活动队列**”模型：

1. 在队列管理中创建或复制命名队列，并添加壁纸。
2. 每块显示器单独选择一个活动队列。
3. 为队列设置顺序或随机播放、循环或播放一次后停止、默认间隔、转场与单项时长覆盖。
4. 可单独开启“视频播放完成后切换下一个壁纸”；开启后视频结束即推进队列，并避免与视频循环重复触发。
5. 删除被使用的队列时，对应显示器会自动回退到固定存在的默认队列。

显示器断开时，应用会保留之前的分配。恢复连接后，按提示选择恢复旧配置或作为新的显示器配置继续使用。

### 菜单栏控制

关闭主窗口后，WallpaperMac 仍可通过菜单栏图标运行。菜单提供：

- 打开 WallpaperMac；
- 暂停或恢复动态壁纸；
- 静音或取消静音；
- 打开壁纸库或设置；
- 完全退出应用。

## 网页壁纸测试模板

仓库附带一个离线、最小化的网页壁纸模板：

```text
Templates/SimpleWebWallpaper/
```

它包含 `index.html`、`styles.css`、`script.js` 与说明文件，显示本地时钟及轻量背景动画。可直接把整个目录拖入 WallpaperMac 来测试网页导入、入口选择与播放器控制。

```bash
# 校验模板仍不依赖网络且入口文件结构正确
./scripts/validate-web-wallpaper-template.sh
```

参见 [网页壁纸模板导入说明](docs/guides/web-wallpaper-template.md)。

## 开发、测试与发布

### 日常验证

```bash
# 校验网页模板
./scripts/validate-web-wallpaper-template.sh

# 运行核心领域与存储回归测试
swift run WallpaperMacCoreTests

# Debug 构建
swift build

# 检查空白错误
git diff --check
```

### 发布验证与打包

```bash
# 完整本地发布检查：模板、测试、Debug/Release 构建、App/ZIP、播放器和 Bundle
./scripts/test-release.sh

# 验证连续队列切换中的播放器释放和内存回归
./scripts/queue-memory-regression.sh

# 生成并验证 DMG
./scripts/build-dmg.sh
```

发布产物生成在 `dist/`：

```text
WallpaperMac.app
WallpaperMac-v<version>-macOS.zip
WallpaperMac-v<version>-macOS.dmg
```

这些文件是可再生二进制产物，不提交到 Git。版本号来自根目录 [`VERSION`](VERSION)，具体发布内容见 [`CHANGELOG.md`](CHANGELOG.md) 和 [`docs/release-notes/`](docs/release-notes/)。

GitHub Actions 在 macOS runner 上自动验证网页模板、`swift build` 和 `WallpaperMacCoreTests`。与真实桌面会话相关的播放器、状态栏、多显示器、签名、DMG 挂载和内存压力验证仍需在本地 macOS 环境执行。

## 仓库结构

```text
WallpaperMac/
├── .github/                         # CI、Issue 表单与 Pull Request 模板
├── Assets/                          # 应用图标与品牌资源
├── Sources/
│   ├── WallpaperMac/                # SwiftUI + AppKit 应用层、窗口和播放器承载
│   ├── WallpaperMacCore/            # 领域模型、JSON 存储、队列与布局契约
│   └── WallpaperMacCoreTests/       # 无 XCTest 依赖的可执行核心回归测试
├── Templates/
│   └── SimpleWebWallpaper/          # 离线网页壁纸导入测试模板
├── docs/
│   ├── design/                      # UI 规范、页面蓝图与实现契约
│   ├── development/                 # 构建、验证与发布流程
│   ├── guides/                      # 使用与网页壁纸指南
│   ├── release-notes/               # 版本发布说明
│   └── superpowers/                 # 历史设计决策与实施计划
├── scripts/                         # 构建、打包、运行时与内存回归脚本
├── CHANGELOG.md                     # 简明变更记录
├── CONTRIBUTING.md                  # 贡献约定
├── SECURITY.md                      # 安全问题报告方式
├── Package.swift                    # SwiftPM 定义
└── VERSION                          # 当前版本号
```

`dist/`、`.build/`、Finder 元数据、用户壁纸索引和日志被 `.gitignore` 排除。项目尚未声明开源许可证；在将仓库公开发布或接受外部代码前，请由项目所有者选择并添加适当的 `LICENSE`。

## 文档与支持

- [文档中心](docs/README.md)
- [快速开始](docs/guides/quick-start.md)
- [构建、验证与发布](docs/development/build-and-release.md)
- [设计文档](docs/design/README.md)
- [贡献指南](CONTRIBUTING.md)
- [安全政策](SECURITY.md)
- [更新记录](CHANGELOG.md)

遇到问题时，请使用 GitHub 的 Bug Report 模板，提供 WallpaperMac 版本、macOS 版本、素材类型、导入方式和最小复现步骤。请不要上传私人壁纸、完整用户目录、Cookie、Token、证书或其他敏感信息。
