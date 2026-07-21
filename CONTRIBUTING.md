# 贡献指南

感谢你愿意改进 WallpaperMac。本仓库是一个 macOS 13+ 的 Swift Package：UI 层使用 SwiftUI 与 AppKit，核心数据模型和存储逻辑位于独立的 `WallpaperMacCore` Target。提交前请先熟悉 [README](README.md)、[开发与发布指南](docs/development/build-and-release.md) 和现有发布说明。

## 开始前

1. 阅读现有 Issue，避免重复工作；新增功能请先说明具体的本地壁纸工作流和边界。
2. 对涉及 UI、队列策略、导入格式或持久化数据的改动，先提出简短设计说明，再开始实现。
3. 不要提交私人壁纸、视频、网页项目、用户资源索引、日志、Cookie、证书或签名身份。
4. 不要擅自引入远程 URL 壁纸、账号体系、云同步或在线素材市场；这些不属于当前产品范围。

## 本地开发

```bash
git clone <你的仓库地址>
cd WallpaperMac
swift --version
swift build
swift run WallpaperMacCoreTests
```

使用下面的命令构建可打开的本地 App Bundle：

```bash
./scripts/package-release.sh
open dist/WallpaperMac.app
```

所有构建产物位于 `.build/` 或 `dist/`，已由 `.gitignore` 排除。

## 代码组织与约定

- `Sources/WallpaperMacCore/`：可复用的领域模型、JSON 存储、队列与预览布局契约。这里的逻辑应尽量不依赖 AppKit 窗口生命周期。
- `Sources/WallpaperMac/`：SwiftUI 页面、AppKit 窗口、状态栏、显示器发现和播放器承载。
- `Sources/WallpaperMacCoreTests/main.swift`：无需 XCTest 的可执行核心回归测试。新增核心行为时，请将相应测试加入这里。
- `Templates/`：随应用发布的离线网页壁纸示例；资源必须采用相对路径且不依赖网络。
- `scripts/`：可重复执行的构建、封装、运行时和发布验证脚本。

请遵循项目已有的命名和 Swift 风格。避免为简单需求引入新的第三方依赖或改变既有 JSON 格式；若确实需要扩展数据模型，必须为旧索引提供可预测的默认值和回归测试。

## 测试要求

提交前至少运行：

```bash
./scripts/validate-web-wallpaper-template.sh
swift run WallpaperMacCoreTests
swift build
git diff --check
```

以下检查需要真实 macOS 桌面环境，通常在准备发布时运行：

```bash
./scripts/test-release.sh
./scripts/player-runtime-test.sh
./scripts/queue-memory-regression.sh
./scripts/build-dmg.sh
```

UI、视频和 `WKWebView` 改动还应手工检查：导入、检查器预览、显示器应用、暂停/恢复、静音、队列切换和退出后的资源释放。若修改预览布局，请用竖屏资源确认卡片和检查器仍保持固定 16:9 容器。

## 提交与 Pull Request

- 每个提交聚焦一个可审查的目的，例如 `fix: 修复队列切换后的播放器释放` 或 `docs: 补充安装说明`。
- PR 描述应说明用户可见行为、受影响的资源类型、兼容性和实际执行过的验证命令。
- 不要把 `dist/`、`.build/` 或单纯格式化的无关改动混入功能 PR。
- 如果改动影响版本行为，请更新 `CHANGELOG.md`，必要时补充 `docs/release-notes/` 条目。

## 行为边界

WallpaperMac 当前只支持本地图片、视频和本地 HTML 项目。外部文件引用只能移除应用记录，不能删除用户原始文件；应用库副本才可以由应用托管删除。请在修改导入、删除或失效资源处理时保留这一约束。
