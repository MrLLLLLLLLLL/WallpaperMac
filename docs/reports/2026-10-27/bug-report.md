# WallpaperMac Bug 报告

- **日期**：2026-10-27
- **排查范围**：全仓约 10,400 行 Swift + 发布/更新脚本（含未提交的自动更新模块）
- **方法**：分区静态审查 + 交叉验证 + 运行全量测试 + 窗口生命周期实验 + 逐条源码核查
- **测试状态**：`swift run WallpaperMacCoreTests` 全量 70/70 通过（含新增更新模块测试，断言与实现一致）
- **说明**：本报告由初版排查报告整合核查结论而成。每项均标注核查结果；个别表述已修正夸大或行号偏差。报告期间未修改任何项目文件。

---

## 高危

### 1. `readFrame` 锁间竞态 → 数组越界崩溃

**位置**：[WallpaperVideoStreamController.swift:250](../../../Sources/WallpaperMac/WallpaperVideoStreamController.swift:250)

循环以「缓冲区已满一帧」退出（:234 break）后、最终加锁（:248）之间不复核 `bufferedData.count`。若 `teardown()`(:93) 或 `processDidTerminate()`(:205) 在此窗口内执行 `bufferedData.removeAll()`，随后 `removeSubrange(0..<frameSize)` 对不足帧长的 Data 操作直接 `fatalError`（越界）。

**触发**：视频播完瞬间 ffmpeg 退出与最后一帧提取天然并发——"播完切换下一个"队列每播完一个视频就有一次竞争机会；队列切换壁纸的 teardown 若落入同一窗口亦同。竞态窗口虽窄（几条指令），但高频率场景下会被反复命中。

**核查结论**：✅ 属实。机制描述正确；初版"长运行必现"表述夸大，精确说法是"小窗口竞态、每次播完有一次机会"。注意：循环内阻塞 `read()` 期间被清空的场景会安全返回 nil，不会崩。

**修复方向**：最终加锁后重新校验 `bufferedData.count >= frameSize`，不足则返回 nil（或把「判断满帧 + 取帧」合并进同一个临界区）。

---

### 2. 队列编辑器保存丢失删除与排序

**位置**：[MainView.swift:585](../../../Sources/WallpaperMac/MainView.swift:585) + [PlaybackQueue.swift:124](../../../Sources/WallpaperMacCore/PlaybackQueue.swift:124)

`saveQueue` 用 `queue.addWallpaperIDs(...)` 合并，而该方法只追加、不替换、不重排。编辑器里的「移出队列」(:1401) 和拖动/上下移（:1472–1484）只改本地 `@State wallpaperIDs`，保存后原 ID 仍在队列且顺序不变。

**触发**：配置队列 → 删掉一项或调整顺序 → 保存 → 重开编辑器，改动消失。只有新增、间隔、转场生效。

**核查结论**：✅ 属实。注意影响范围：此 bug 只影响 MainView 的 `QueueEditorView`（显示器队列编辑弹窗）；`QueueManagementView`（队列管理页）走 `removeWallpapers`/`moveWallpaper` 即时 mutate 路径，不受影响。

**修复方向**：保存改为全量替换 `wallpaperIDs`（或提供 `setWallpaperIDs` 语义），而非合并追加。

---

## 中危

### 3. 多文件拖放只导入 1 个

**位置**：[MainView.swift:660](../../../Sources/WallpaperMac/MainView.swift:660)

每个 `NSItemProvider` 各自调 `beginImport([url])`(:679)，`pendingImportURLs` 被逐个覆盖，先到的扫描结果被 `guard pendingImportURLs == urls`(:626) 丢弃。一次拖 3 个文件只剩最后一个。

**核查结论**：✅ 属实。

---

### 4. 视频播完可能双跳队列

**位置**：[WallpaperManager.swift:811](../../../Sources/WallpaperMac/WallpaperManager.swift:811)

`videoPlaybackDidFinish(for:)` 不携带「哪个视频播完」的身份；`notifyPlaybackCompleted` 无条件派发到 main，旧 controller 在转场 teardown 后回调仍可到达。若此时当前项已是新视频，会按新当前项再 `advanceQueue` 一次，跳过刚应用的壁纸。

**核查结论**：✅ 属实。

---

### 5. 未知时长视频被看门狗 300 秒截断

**位置**：[PlaybackQueue.swift:183](../../../Sources/WallpaperMacCore/PlaybackQueue.swift:183)

`durationSeconds == nil` 时看门狗为 `max(defaultIntervalSeconds, 300)`。注释声称"不截断健康长视频"，但任何 >5 分钟且元数据缺失的视频播到 5 分钟即被强制切走。现有测试（[main.swift:912](../../../Sources/WallpaperMacCoreTests/main.swift:912) 附近）固化了该行为，与测试文案 "does not cut healthy long videos" 自相矛盾。

**补充条件**：仅当 `defaultIntervalSeconds ≤ 300` 时被 300 截断；队列间隔更大时看门狗取 `defaultIntervalSeconds`。

**核查结论**：✅ 属实。

---

### 6. 缩略图在渲染路径同步读盘

**位置**：[MainView.swift:2145](../../../Sources/WallpaperMac/MainView.swift:2145)、[WallpaperManager.swift:1283](../../../Sources/WallpaperMac/WallpaperManager.swift:1283)

`previewImage` / `isPortraitAsset` 计算属性每次渲染同步 `NSImage(contentsOf:)` 解码，无缓存。网格每次选中/搜索都全量重读，大图库主线程卡顿。（`isPortraitAsset` 优先读 metadata，缺失时才读盘。）

**核查结论**：✅ 属实。

---

### 7.（新代码）更新下载逐字节迭代

**位置**：[UpdateDownloader.swift:236](../../../Sources/WallpaperMacCore/Update/UpdateDownloader.swift:236)

`for try await byte in bytes` 对数百 MB 的 zip 每字节一次异步迭代，下载速度会被 CPU 拖死。应改 `URLSession.download` 或分块读。

**核查结论**：✅ 属实。

---

### 8.（新代码）更新解压阻塞主线程

**位置**：[SettingsWindowController.swift:236](../../../Sources/WallpaperMac/SettingsWindowController.swift:236)

`Task {}` 继承 MainActor（SwiftUI `View` 协议 @MainActor 隔离），同步调用 `UpdateInstaller.prepare` 内的 `ditto + waitUntilExit`（[UpdateInstaller.swift:99](../../../Sources/WallpaperMacCore/Update/UpdateInstaller.swift:99)）。下载完成后 UI 冻结至解压结束。代码内部又用 `await MainActor.run` 包 `updatePhase` 赋值，自相矛盾地印证了这一点。

**核查结论**：✅ 属实。

---

### 9.（新代码）"启动时每日检查一次"名不副实

**位置**：[SettingsWindowController.swift:258](../../../Sources/WallpaperMac/SettingsWindowController.swift:258)

`runDailyUpdateCheckIfNeeded` 全局唯一调用点是 `SettingsView.onAppear`(:360)，应用启动入口无任何调用。实测（最小 AppKit+SwiftUI 实验）确认 `onAppear` 在窗口关闭/重开时不会重入——实际行为是"每次启动后**首次**打开设置时检查一次"，不开设置永不检查，与文案完全不符。

**核查结论**：✅ 属实。

---

### 10. 遗留队列迁移非原子

**位置**：[WallpaperStore.swift:206](../../../Sources/WallpaperMacCore/WallpaperStore.swift:206)

先写 `playback-queues.json` 再写 `display-playback-bindings.json`；guard(:164–166) 要求两文件都不存在才迁移。中间崩溃/失败后 guard 永久跳过迁移，所有显示器→队列绑定静默丢失。

**核查结论**：✅ 属实。

---

### 11. 用 `hasDirectoryPath` 语法判断目录

**位置**：[WallpaperStore.swift:661](../../../Sources/WallpaperMacCore/WallpaperStore.swift:661)

`URL.hasDirectoryPath` 只看路径有无尾斜杠。无尾斜杠的目录 URL（拖放产生）会让 web 项目 entry 校验退化为"entry 必须等于 source"，导入报 `invalidHTMLEntry`。同文件 :269 用 `resourceValues(.isDirectoryKey)` 正确判断目录，两种标准混用；测试均用 `isDirectory: true` 构造 URL，未覆盖此形态。

**核查结论**：✅ 属实。

---

## 低危

| # | 问题 | 位置 | 核查 |
|---|---|---|---|
| 12 | `remove` 先删资源文件后写索引，save 失败留幻影条目 | [WallpaperStore.swift:475](../../../Sources/WallpaperMacCore/WallpaperStore.swift:475) | ✅ |
| 13 | `teardown` 与 `startProcess` 竞争遗留无主 ffmpeg（自愈：播完自然退出） | [WallpaperVideoStreamController.swift:124](../../../Sources/WallpaperMac/WallpaperVideoStreamController.swift:124) | ✅ |
| 14 | 损坏存档出现重复 ID 时 `Dictionary(uniqueKeysWithValues:)` 直接崩溃 | [WallpaperManager.swift:218](../../../Sources/WallpaperMac/WallpaperManager.swift:218) | ✅ |
| 15 | 相同文案 toast 被上一个定时器提前清掉（含撤销操作） | [MainView.swift:964](../../../Sources/WallpaperMac/MainView.swift:964) | ✅ |
| 16 | `onDisappear` 的取消逻辑经实测在关窗时**不触发**（死代码）；若真触发又会误取消进行中的更新——更新生命周期应移出视图 | [SettingsWindowController.swift:362](../../../Sources/WallpaperMac/SettingsWindowController.swift:362) | ✅ |
| 17 | 签名验证把整个 zip 读入内存，与流式哈希设计矛盾 | [UpdateSignature.swift:40](../../../Sources/WallpaperMacCore/Update/UpdateSignature.swift:40) | ✅（[UpdateDownloader.swift:163](../../../Sources/WallpaperMacCore/Update/UpdateDownloader.swift:163) 确用 `verify(fileAt:)`） |
| 18 | `prepare` 的 stderr 管道 >64KB 时 `waitUntilExit` 潜在死锁 | [UpdateInstaller.swift:95](../../../Sources/WallpaperMacCore/Update/UpdateInstaller.swift:95) | ✅ |
| 19 | 安装脚本 `kill -0 $PARENT_PID` 遇 PID 复用会永久等待；staging 目录（zip+解压物，UUID 子目录）从不主动清理 | [UpdateInstaller.swift:180](../../../Sources/WallpaperMacCore/Update/UpdateInstaller.swift:180) | ✅ |
| 20 | `isZipAssetName` 宽松匹配 `WallpaperMac-evil-macOS.zip`（有签名校验兜底，建议收紧） | [UpdateChecker.swift:136](../../../Sources/WallpaperMacCore/Update/UpdateChecker.swift:136) | ✅ |
| 21 | `build-release.sh` 只删旧 zip 不删旧版本 `.zip.sig`/`SHA256SUMS`（:41 仅清理当前版本 sig）；smoke 脚本回退路径硬编码 v0.2.5 | [update-artifact-smoke.sh:100](../../../scripts/update-artifact-smoke.sh:100) | ✅ |
| 22 | 菜单栏"暂停动态壁纸"标题不随播放状态变化 | [StatusBarController.swift:63](../../../Sources/WallpaperMac/StatusBarController.swift:63) | ✅（初版行号 66 有偏差） |
| 23 | 测试名与覆盖不符（`testUpdatePreflightRejectsTranslocatedAndUnwritable` 未测 unwritable 分支，仅测 translocated/bare-binary/writable-pass） | [main.swift:1328](../../../Sources/WallpaperMacCoreTests/main.swift:1328) | ✅（初版锚点 453 有偏差） |

---

## 待确认 / 设计权衡

- **严格 decode 能否读取旧版存档**：`WallpaperItem.init(from:)` 多字段（`availability`/`createdAt` 等）无默认值，旧档缺字段会整档解析失败；git 历史已 squash，无法核实旧 schema。⚠️ 有条件成立。
- **单文件 `.html` 导入拷贝父目录**：[WallpaperStore.swift:270](../../../Sources/WallpaperMacCore/WallpaperStore.swift:270) 对非目录 web 源取 `deletingLastPathComponent()` 整体拷贝（如拷走整个 Downloads），测试固化为设计行为，磁盘爆炸风险大。✅ 属实。
- **`onAppear` 回写 `launchAtLogin` 触发 `onChange`**：`@AppStorage` 初值与 `LoginItemService.isEnabled` 不一致时，会多调一次 `setEnabled`。⚠️ 有条件成立。
- **`reload` 不重置队列定时器**；元数据全量写回的并发覆盖窗口；FileHandle 并发 close/read。✅ 经抽查成立。

---

## 总评与修复建议

- 全量测试 70/70 通过；签名验证链（Ed25519 + SHA-256 + fail-closed）设计健全，问题集中在实现细节。
- 报告共 26 项发现，经逐条源码核查**无误报**；初版"必现"等表述与 2 处行号偏差已在上文修正。
- **建议修复顺序**：高危 1（readFrame 崩溃）与高危 2（队列保存丢失）优先；随后中危 3、4、9（用户可直接感知的功能性缺陷），再处理更新模块（7、8、19）与其余性能/健壮性问题。
