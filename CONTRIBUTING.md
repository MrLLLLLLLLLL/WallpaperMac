# 贡献指南

感谢你改进 WallpaperMac。项目是 macOS 13+ 的 Swift Package：UI 使用 SwiftUI/AppKit，领域模型与可测试策略位于独立的 `WallpaperMacCore` target。开始改动前请阅读 [README](README.md)、[安全政策](SECURITY.md) 和现有 [更新记录](CHANGELOG.md)。

本项目采用 [GPL-3.0-or-later](LICENSE)。提交代码即表示你有权提交，并同意贡献按同一许可证发布。

## 1. 产品边界与改动原则

- 先阅读现有 Issue，避免重复工作；新功能先描述具体的本地壁纸工作流、边界和失败行为。
- 涉及 UI、队列、导入格式、持久化、系统设置或锁屏同步的改动，先写简短设计说明。
- 不要提交私人壁纸、用户资源索引、日志、Cookie、证书、密钥、签名身份或完整用户目录。
- 不引入账号体系、云同步或在线素材市场。HTTP/HTTPS 网页壁纸自 0.2.8 起已支持，新增远程来源仍需先说明隐私与失败策略。
- 不为了简单需求引入第三方依赖。扩展 JSON 数据模型时，必须为旧记录提供可预测的默认值、迁移路径和回归测试。
- 发布、打标签、上传 Release 只在维护者明确要求时进行；普通功能提交不自动发版。

## 2. 本地开发

```bash
git clone <你的仓库地址>
cd WallpaperMac
swift --version
swift build
swift run WallpaperMacCoreTests
```

生成可启动的 App Bundle：

```bash
./scripts/package-release.sh
open dist/WallpaperMac.app
```

`package-release.sh` 会重新创建 `dist/WallpaperMac.app`、写入版本信息、内置 ffmpeg 及动态库并做 ad-hoc 签名，不做 Developer ID 或 Apple 公证。`.build/`、`dist/` 均已被 `.gitignore` 排除。

## 3. 代码组织

- `Sources/WallpaperMacCore/`：可复用模型、JSON 存储、队列/布局契约、更新验证、快捷键模型和纯策略。这里应尽量不依赖 AppKit 窗口生命周期，便于核心测试。
- `Sources/WallpaperMac/`：SwiftUI 视图、AppKit 窗口、状态栏、显示器发现、播放器、更新生命周期、快捷键注册和锁屏同步。
- `Sources/WallpaperMacCoreTests/main.swift`：自建可执行回归测试 runner，不使用 XCTest。新增测试函数后必须注册到 `tests` 数组，否则不会运行。
- `Templates/`：离线网页模板，资源必须相对路径且不依赖网络。
- `scripts/`：构建、签名、发布、运行时测试和共享测试状态守护库。

### 持久化与兼容性约束

详细协议见 [存储与恢复协议](docs/development/storage-and-recovery.md)。

- managedCopy 资源使用 `Assets/{UUID}/{原始文件名}`；旧 `Assets/{UUID}-{原始文件名}` 必须在加载时迁移，不能只改新导入路径。
- 外部引用只能移除索引记录，不能删除用户原文件；托管副本才可以由应用删除。
- 修改 sourceURL、entryURL、thumbnailURL、playbackURL 或恢复逻辑时，同时考虑 `wallpapers.json` 与 `wallpapers.json.bak`。
- 恢复标记未清除前，不允许保存布局迁移或执行可能删除资源的孤儿清理。
- 队列/分配/档案写盘共享防抖写器时，每次调度必须携带完整快照，不能只携带某个域的部分状态。
- 不要把用户播放意图与系统挂起混为一谈：睡眠、锁屏、全屏和电池策略不得擅自改写保存的 `isEnabled/isPlaying` 意图。

### 系统集成约束

- 快捷键使用 Carbon，修饰键必须转换为 Carbon mask，不能直接保存 `NSEvent.ModifierFlags`。新组合先注册成功再替换旧组合；失败不得覆盖旧偏好。
- 普通全局热键非独占，系统预检和 Carbon 错误不等于能枚举所有第三方冲突，UI/文档必须保留这一限制。
- 锁屏同步只使用公开的 `NSWorkspace.setDesktopImageURL`，使用静态原图、缩略图或页面快照，不修改私有锁屏缓存、FileVault/preboot 或登录窗口文件。默认关闭，不实现为视频/网页持续动画。
- 更新安装必须复用现有 SHA-256、Ed25519、安装锁、原子交换、健康握手和回滚链路，不另写绕过验证的安装路径。

## 4. 测试要求

提交前至少运行：

```bash
./scripts/validate-web-wallpaper-template.sh
swift build
swift run WallpaperMacCoreTests
git diff --check
```

核心测试只依赖 `WallpaperMacCore`，适合覆盖：

- 模型编解码与旧 JSON 默认值
- 导入、删除、重定位、资源路径迁移、备份恢复和孤儿清理
- 队列/绑定/调度、显示器身份和布局纯逻辑
- 视频容器、流式生命周期和网页授权纯逻辑
- 快捷键结构、更新节流和锁屏静态资源选择

真实 AppKit、Carbon、AVPlayer、WKWebView、菜单栏、DMG、签名和更新安装依赖本地 macOS 图形会话。准备发布时运行：

```bash
./scripts/test-release.sh   # 已包含内存回归与版本一致性校验
./scripts/build-release.sh
```

按需进行人工验收：

- 图片、视频、网页各至少一个导入、预览、应用、暂停/恢复和删除流程。
- 多显示器应用、热插拔、全屏暂停、睡眠/锁屏恢复、隐藏模式切换。
- 自定义快捷键、系统冲突回滚、重启后的偏好保留。
- 锁屏开关、当前壁纸变化、视频缩略图、网页快照、详情上传覆盖图和退出恢复原图；不要要求 FileVault 登录界面同步。
- 队列连续切换后的资源释放、播放器内存和更新安装/回滚。

运行时脚本可能启动/终止测试 App、修改临时 defaults 并调用录屏或辅助功能；不要在无人值守的真实工作会话中运行。`scripts/lib/test-state-guard.sh` 负责备份和恢复偏好与 Configuration，新增测试写新偏好键时应同步加入清理列表。

## 5. 提交与 Pull Request

- 一个提交聚焦一个可审查目的，例如 `fix: 修复队列切换后的播放器释放` 或 `docs: 重构安装与数据说明`。
- PR 描述说明用户可见行为、受影响资源类型、兼容性、系统边界，以及实际执行过的验证命令。
- 不把 `dist/`、`.build/` 或无关格式化改动混入功能 PR。
- 影响版本行为时更新 `CHANGELOG.md`；需要发布说明时在本地 `docs/release-notes/` 补充，但该目录按项目约定不随公开仓库分发。
- 不要通过 PR 修改发布公钥、签名密钥、私有用户文档或真实用户数据。

## 6. 发布流程

只有维护者明确要求时才执行：

1. 确认 `VERSION`、`ApplicationVersionInfo.developmentFallbackVersion`、README 当前版本、`CHANGELOG.md` 和 `docs/release-notes/<version>.md` 已同步，工作区干净。
2. 设置 `WALLPAPERMAC_UPDATE_SIGNING_KEY` 与 `WALLPAPERMAC_UPDATE_SIGNING_PUBLIC_KEY`（worktree 中指向主 checkout），运行 `./scripts/test-release.sh`，必须输出 `ALL_RELEASE_TESTS_PASSED`。
3. 运行 `./scripts/build-release.sh`，生成同源 ZIP、DMG、`.zip.sig` 和 `SHA256SUMS.txt`。缺私钥时 fail-closed；`WALLPAPERMAC_ALLOW_UNSIGNED=1` 只供本地开发。
4. 运行 `./scripts/publish-release.sh --yes`，创建标签、推送、创建 Release 上传四个产物，并自动用生产模式 `update-artifact-smoke.sh` 校验线上产物，要求输出 `PUBLISH_RELEASE_PASSED`。
5. 真机升级验收：从上一版本检查更新，确认退出、替换、自动重启，壁纸库/队列/分配保留，再次检查显示最新，必要时验证 `.previous` 回滚。

注意：`secrets/` 和更新私钥永不提交；发布公钥内嵌于 `Sources/WallpaperMacCore/Update/UpdateSignature.swift`。worktree 缺少 gitignored 私钥/公钥时，分别用 `WALLPAPERMAC_UPDATE_SIGNING_KEY`、`WALLPAPERMAC_UPDATE_SIGNING_PUBLIC_KEY` 指向主 checkout。正式对外分发前完成 Developer ID 签名和 Apple 公证。0.2.8–0.2.13 用户需用最新 DMG（至少 0.2.15）手动覆盖安装一次，发布说明必须保留该指引；0.2.14 用户应尽快升级以避开持久化缺陷。
