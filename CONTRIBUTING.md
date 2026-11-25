# 贡献指南

感谢你愿意改进 WallpaperMac。本仓库是一个 macOS 13+ 的 Swift Package：UI 层使用 SwiftUI 与 AppKit，核心数据模型和存储逻辑位于独立的 `WallpaperMacCore` Target。提交前请先熟悉 [README](README.md)、本贡献指南与现有 `CHANGELOG.md`。

本项目采用 [GPL-3.0-or-later](LICENSE)。向本仓库提交代码即表示你确认自己有权提交该内容，并同意该贡献按同一许可证随项目发布。

## 开始前

1. 阅读现有 Issue，避免重复工作；新增功能请先说明具体的本地壁纸工作流和边界。
2. 对涉及 UI、队列策略、导入格式或持久化数据的改动，先提出简短设计说明，再开始实现。
3. 不要提交私人壁纸、视频、网页项目、用户资源索引、日志、Cookie、证书或签名身份。
4. 不要擅自引入账号体系、云同步或在线素材市场；这些不属于当前产品范围。HTTP/HTTPS 网页壁纸自 0.2.8 起已支持，但新增远程来源仍需先提出设计说明。

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
./scripts/test-release.sh   # 已包含播放器矩阵、内存回归与版本一致性校验
./scripts/build-dmg.sh
```

UI、视频和 `WKWebView` 改动还应手工检查：导入、检查器预览、显示器应用、暂停/恢复、静音、队列切换和退出后的资源释放。若修改预览布局，请用竖屏资源确认卡片和检查器仍保持固定 16:9 容器。

## 提交与 Pull Request

- 每个提交聚焦一个可审查的目的，例如 `fix: 修复队列切换后的播放器释放` 或 `docs: 补充安装说明`。
- PR 描述应说明用户可见行为、受影响的资源类型、兼容性和实际执行过的验证命令。
- 不要把 `dist/`、`.build/` 或单纯格式化的无关改动混入功能 PR。
- 如果改动影响版本行为，请更新 `CHANGELOG.md`，必要时在本地补充发布说明（`docs/release-notes/`，不随仓库发布）。

## 发布流程

发布只在维护者明确要求时进行。步骤：

1. 确认 `VERSION`、`ApplicationVersionInfo.developmentFallbackVersion`、`CHANGELOG.md` 段落、`docs/release-notes/<version>.md` 已同步，工作区干净。
2. `WALLPAPERMAC_UPDATE_SIGNING_KEY="$PWD/secrets/WallpaperMac.update.key" ./scripts/test-release.sh`，必须输出 `ALL_RELEASE_TESTS_PASSED`。
3. `./scripts/build-release.sh` 生成并签名 ZIP/DMG/SHA256SUMS（缺私钥 fail-closed）。
4. `./scripts/publish-release.sh --yes`：打 `v<x.y.z>` 标签、推送、`gh release create` 上传四个产物，随后自动运行生产模式 `update-artifact-smoke.sh` 校验线上产物，输出 `PUBLISH_RELEASE_PASSED`。
5. 真机升级验收：从上一版本检查更新，确认退出、替换、自动重启，壁纸库/队列/分配保留，再次检查显示最新。

注意：`secrets/` 与更新私钥永不提交；发布公钥内嵌于 `Sources/WallpaperMacCore/Update/UpdateSignature.swift`。App 使用 ad-hoc 签名，正式对外分发前应完成 Developer ID 签名与 Apple 公证。0.2.8–0.2.13 用户需手动安装一次 0.2.14 才能恢复自动更新，发布说明必须保留该指引。

## 行为边界

WallpaperMac 支持本地图片、视频、本地 HTML 项目，以及 HTTP/HTTPS 网页壁纸（0.2.8 起）。外部文件引用只能移除应用记录，不能删除用户原始文件；应用库副本才可以由应用托管删除。请在修改导入、删除或失效资源处理时保留这一约束。
