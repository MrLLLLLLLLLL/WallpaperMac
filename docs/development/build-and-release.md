# 构建、验证与发布

本项目使用 Swift Package Manager 构建 macOS 13+ 应用。核心逻辑测试是一个可执行 Target，因此不依赖当前机器是否安装 XCTest 或 Swift Testing 模块。

## 前置条件

- macOS 13 或更高版本
- 与项目兼容的 Xcode / Command Line Tools 和 Swift 工具链
- 用于 DMG 构建的系统工具：`hdiutil`、`codesign`、`plutil`、`zip`、`unzip`
- 用于打包兼容视频转换器的 ffmpeg；默认读取 `/opt/homebrew/bin/ffmpeg`，也可设置 `WALLPAPERMAC_FFMPEG_SOURCE`

先确认环境：

```bash
swift --version
xcode-select -p
```

## 快速开发循环

```bash
# 编译 Debug 版本
swift build

# 运行核心领域、存储、队列、分页和预览契约回归测试
swift run WallpaperMacCoreTests

# 校验网页壁纸模板的离线相对路径契约
./scripts/validate-web-wallpaper-template.sh
```

若需要启动可打开的 App Bundle：

```bash
./scripts/package-release.sh
open dist/WallpaperMac.app
```

`package-release.sh` 会执行 Release 构建，重新创建 `dist/WallpaperMac.app`，写入 `Info.plist`、复制图标、内置 ffmpeg 及其动态库，并进行 ad-hoc 签名。它不进行 Developer ID 签名或 Apple 公证。

## 验证层级

### GitHub CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) 在 macOS runner 上运行以下无桌面依赖检查：

```bash
./scripts/validate-web-wallpaper-template.sh
swift build
swift run WallpaperMacCoreTests
git diff --check HEAD^
```

CI 不替代真实桌面验证：显示器分配、`AVPlayer`、`WKWebView`、状态栏、Gatekeeper、代码签名和 DMG 挂载都与当前机器及图形会话相关。

### 本地发布前检查

```bash
# 执行模板、核心测试、Debug/Release 构建、App/ZIP、播放器矩阵和 Bundle 检查
./scripts/test-release.sh

# 专门验证图片、视频和网页播放器承载路径
./scripts/player-runtime-test.sh

# 专门验证 AV1 转换、引用原文件不复制和兼容缓存
./scripts/video-codec-runtime-test.sh

# 专门验证队列重复切换期间播放器会被释放，内存不会单调上升
./scripts/queue-memory-regression.sh
```

如果改动涉及 UI、导入、播放器或队列，请打开刚构建的 `dist/WallpaperMac.app`，手工检查至少一个图片、一个视频、一个本地 HTML 项目，以及主显示器与额外显示器（若可用）。

## 生成 ZIP 和 DMG

版本号由根目录 `VERSION` 控制，格式必须是 `major.minor.patch`。修改版本前请同步更新 `CHANGELOG.md` 与对应的 `docs/release-notes/<version>.md`。

```bash
# 生成 App Bundle 与版本化 ZIP
./scripts/build-release.sh

# 重新构建 App Bundle，生成并验证版本化 DMG
./scripts/build-dmg.sh
```

产物位于：

```text
dist/WallpaperMac.app
dist/WallpaperMac-v<version>-macOS.zip
dist/WallpaperMac-v<version>-macOS.dmg
```

`dist/` 是可再生发布目录，已被 Git 忽略。发布时应独立上传最终 ZIP/DMG 和其脚本输出的 SHA-256，而不是把二进制产物提交到源码仓库。

## 建议的发布检查表

1. 确认 `VERSION`、`CHANGELOG.md`、README 当前版本和发布说明一致。
2. 在干净工作区运行 `git diff --check`。
3. 运行 `./scripts/test-release.sh`、`./scripts/queue-memory-regression.sh` 与 `./scripts/build-dmg.sh`。
4. 使用 `hdiutil attach` 或 Finder 挂载 DMG，确认其中有 `WallpaperMac.app` 和 `Applications` 快捷方式。
5. 用 `codesign --verify --deep --strict --verbose=2 dist/WallpaperMac.app` 复查 App Bundle。
6. 在目标 macOS 版本启动 App，确认菜单栏图标、持久化壁纸库和至少一条动态队列。
7. 上传 ZIP/DMG、SHA-256、发布说明；如面向外部分发，完成 Developer ID 签名和 Apple 公证后再发布。

## 仓库清理

不要提交 `.build/`、`dist/`、`.DS_Store`、AppleDouble `._*` 文件、Xcode 用户状态、日志、崩溃报告或应用数据 JSON。详见根目录 [`.gitignore`](../../.gitignore)。
