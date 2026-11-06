# WallpaperMac 修复评审报告

- **日期**：2026-10-27
- **评审对象**：针对 [BugReport-2026-10-27.md](bug-report.md) 所列问题的修复改动（当前工作区未提交状态）：14 个修改文件 + 6 个新增文件，约 +1436 / −101 行
- **方法**：逐条 diff 审读 + 关键论断回源码验证 + 全量测试 + 编译验证 + 子代理分区交叉评审（存储层 / 更新模块）
- **测试状态**：`swift run WallpaperMacCoreTests` 全量 **78/78 通过**（较修复前 +8）；`swift build` 通过
- **评审结论**：**有条件通过——建议修复 1 个新引入的高危问题与 2 个中危回归后再合入**。原报告两个高危均已正确修复；修复整体方向正确、架构有明显提升；但看门狗心跳实现引入了新的线程安全高危 bug，遗留队列迁移修复对旧迁移用户存在覆盖回归。

---

## 一、总结

| 类别 | 数量 | 说明 |
|---|---|---|
| 原问题已正确修复 | 18 | 含全部 2 个高危、6 个中危、多个低危与全部 4 个"待确认" |
| 原问题部分修复 | 4 | 迁移原子性、staging 清理、缩略图 I/O、脚本收尾 |
| 原问题未修 | 4 | 签名整读内存、队列编辑器 move 丢行、smoke 脚本、deinit 线程 |
| **新引入问题** | **5** | **1 高危（心跳线程）+ 2 中危（迁移覆盖回归、缓存泄漏）+ 2 低危** |

修复的工程质量整体良好：`PlaybackSession` 会话令牌、`UpdateService` 生命周期解耦、`ProcessRunner` 根治管道死锁、`MetadataPatch` 防覆盖写、迁移的 plan/marker 崩溃恢复协议，都是值得肯定的设计。主要批评集中在：**一处并发疏忽（恰好落在本轮最重要的行为修复上）**、**一处升级路径回归**，以及**注释与实现相反**（比不写注释更危险）。

---

## 二、原问题逐项对照

### 高危

#### 1. `readFrame` 锁间竞态越界崩溃 — ✅ 已正确修复

- **原问题**：[WallpaperVideoStreamController.swift](../../../Sources/WallpaperMac/WallpaperVideoStreamController.swift) 循环退出与最终加锁之间缓冲区可被 `teardown()`/`processDidTerminate()` 清空，`removeSubrange(0..<frameSize)` 越界崩溃。
- **修复**：最终临界区内 `defer { stateLock.unlock() }` + `guard bufferedData.count >= frameSize else { return nil }`（[:285-291](../../../Sources/WallpaperMac/WallpaperVideoStreamController.swift:285)），竞态窗口闭合。返回 nil 语义正确（缓冲被清空意味着管线已终止/重启，`produceFrames` 停止取帧后由重启路径重新拉起）。
- **附带收益**：同文件还修好了两项旧账——teardown 先 `terminate()` 再延迟到 `frameQueue` 关闭句柄（避免 FileHandle 并发 close/read 崩溃）；`process.run()` 后复核 ownership 杜绝无主 ffmpeg（原低危）。
- **评价**：修法正确、范围克制，是本轮最好的一个修复。

#### 2. 队列编辑器保存丢失删除与排序 — ✅ 已正确修复

- **原问题**：`saveQueue` 用 `addWallpaperIDs` 纯追加合并，编辑器的删除/重排保存后丢失。
- **修复**：新增 `PlaybackQueue.replaceWallpaperIDs(_:markingSortMode:)`（[PlaybackQueue.swift:139-149](../../../Sources/WallpaperMacCore/PlaybackQueue.swift:139)）整体替换、去重、裁剪失效 interval overrides、手工排序标记 `.custom` 防自动重排回弹；[MainView.swift:593](../../../Sources/WallpaperMac/MainView.swift:593) 接线为全量替换。
- **评价**：语义正确，`markingSortMode: .custom` 的细节考虑周到（否则后续按 sortMode 自动排序会吞掉手工顺序）。测试 `replaces queue membership keeping order` 覆盖。

### 中危

#### 3. 多文件拖放只导入一个 — ✅ 已修复

新增 `DropURLCollector`（按 index 聚合、失败项跳过、恰好 drain 一次），[MainView.swift:669](../../../Sources/WallpaperMac/MainView.swift:669) 一次性 `beginImport(urls)`。乱序完成、失败 provider、重复 URL 均有测试（`aggregates drop URLs in drag order`）。

#### 4. 视频播完双跳队列 — ✅ 已修复

`PlaybackSession`（token + itemID + displayID，[WallpaperManager.swift:22-33](../../../Sources/WallpaperMac/WallpaperManager.swift:22)）随每次 present/reload 生成；`videoPlaybackDidFinish`（[:891](../../../Sources/WallpaperMac/WallpaperManager.swift:891)）校验 `currentSessions[displayID] == session` **且** `itemID == session.itemID`，迟到的旧 controller 回调被丢弃。修法干净，是正确的身份化方案（而非加时间窗之类的经验补丁）。

#### 5. 未知时长视频被 300 秒截断 — ⚠️ 设计正确，实现引入新高危（见 §3.1）

- **修复设计**：看门狗重定义为"卡死检测器"——未知时长用 60 秒停滞窗口（[PlaybackQueue.swift:206,214](../../../Sources/WallpaperMacCore/PlaybackQueue.swift:206)）；玩家逐帧上报心跳续期；另有 4 小时硬上限（`hardDeadlineInterval`，[:212](../../../Sources/WallpaperMacCore/PlaybackQueue.swift:212)）。健康长视频不再被截断，卡死仍可恢复。设计是对的，测试也同步改写了断言。
- **但是**：心跳的线程实现有严重问题——见 §3.1。**在这个 bug 修复前，看门狗至少还能按预期工作；修复后它在首帧心跳之后实际失明**（详见下文）。

#### 6. 缩略图渲染路径同步磁盘 I/O — ⚠️ 部分修复（引入泄漏，见 §3.3）

新增 `ThumbnailCache`（path+mtime+size 键控 NSCache，避免重复解码）+ `isPortraitAsset` 记忆化。重复 I/O 消除，但 `inflight` 副本字典只增不减，见 §3.3。

#### 7. 更新下载逐字节迭代 — ✅ 已修复

`downloadFile` 改用 `URLSession.download(for:)`（[UpdateDownloader.swift:216](../../../Sources/WallpaperMacCore/Update/UpdateDownloader.swift:216)），系统托管传输，吞吐问题消除。完整性链保持 fail-closed：SHA256SUMS 缺失即拒 → 流式哈希比对 → Ed25519 签名 `.required` 缺失/无效即删包。**体验回归（低）**：`onProgress` 仅在结束时回调一次（[:241](../../../Sources/WallpaperMacCore/Update/UpdateDownloader.swift:241)），下载中进度条退化为不确定转圈。

#### 8. 更新解压阻塞主线程 — ✅ 已修复

新 `UpdateService` 单例用 `Task.detached`（[UpdateService.swift:77](../../../Sources/WallpaperMac/UpdateService.swift:77)）承载下载 + `prepare`（ditto 移出主线程），UI 经 `@MainActor` 回传。`ProcessRunner` 以临时文件接管 stderr + 轮询限时（ditto 120s），根治 `Pipe + waitUntilExit` 的 64KB 死锁。`WallpaperVideoCompatibilityService` 的 ffmpeg 路径同样改法。**小瑕疵**：超时 SIGTERM 后无 SIGKILL 兜底、子进程未 reap。

#### 9. "启动时每日检查一次"名不副实 — ✅ 已修复

AppDelegate 启动时调用 `UpdateService.shared.runDailyCheckIfNeeded()`（[AppDelegate.swift:21](../../../Sources/WallpaperMac/AppDelegate.swift:21)），设置打开时兜底补查（[SettingsWindowController.swift:150](../../../Sources/WallpaperMac/SettingsWindowController.swift:150)）。检查逻辑移出视图、挂单例，顺带修掉了"关窗取消更新任务"与 onDisappear 失效的生命周期问题（原低危）。文案与行为现已一致。

#### 10. 遗留队列迁移非原子 — ⚠️ 部分修复，且引入覆盖回归（见 §3.2）

崩溃恢复协议本身正确：`plan → bindings → queues → marker`，中断后从 plan 重放保持 UUID 稳定（`resumeMigrationFromPlan`）。但对**已完成迁移的旧版用户**有覆盖回归，见 §3.2。

#### 11. `hasDirectoryPath` 语法判断目录 — ✅ 已修复

7 处生产代码全部换成 `URL.isExistingDirectory`（[URLDirectory.swift:9](../../../Sources/WallpaperMacCore/URLDirectory.swift:9)，基于 `resourceValues(.isDirectoryKey)`，语义正确）。**缺口**：全部测试目录都带尾斜杠构造，恰好没有覆盖原 bug 的"无尾斜杠目录 URL"形态。

### 低危与待确认

| 项 | 状态 | 说明 |
|---|---|---|
| remove 先删文件后写索引 | ✅ 主逻辑已修 | 先 `save` 索引再删资源、失败记 orphan；**但孤儿清理组件失效**（§3.4） |
| teardown/startProcess 无主 ffmpeg | ✅ 已修 | run 后复核 ownership |
| `Dictionary(uniqueKeysWithValues:)` 崩溃 | ✅ 已修 | `UniquedDictionary`（首值胜出）替换全部 7 处，有测试 |
| showToast 同文案误清 | ✅ 已修 | toastID 标识 |
| 更新生命周期绑定视图 / onDisappear 失效 | ✅ 已修 | UpdateService 单例承载 |
| prepare / ffmpeg stderr 管道死锁 | ✅ 已修 | ProcessRunner 临时文件 + 超时 |
| isZipAssetName 过宽 | ✅ 已修 | 锚定正则 `^WallpaperMac-v\d+\.\d+\.\d+-macOS\.zip$` + 版本一致性（[UpdateChecker.swift:141-152](../../../Sources/WallpaperMacCore/Update/UpdateChecker.swift:141)） |
| 旧 `.zip.sig` / SUMS 残留 | ✅ 已修 | build-release.sh find 一并清理 |
| StatusBar 菜单标题不随状态 | ✅ 已修 | `NSMenuDelegate.menuNeedsUpdate` + 状态通知 |
| 签名整读内存 | ❌ **未修** | 注释反而与实现相反（§3.5） |
| 队列编辑器 move 丢"已删壁纸"行 | ❌ 未修 | [MainView.swift:1499-1510](../../../Sources/WallpaperMac/MainView.swift:1499) 仍 `queueItems.map(\.id)`；配合 replace 语义后重排会顺带删除占位行，行为更需注意 |
| smoke 脚本硬编码 v0.2.5 / 不验签名 | ❌ 未修 | [update-artifact-smoke.sh:100](../../../scripts/update-artifact-smoke.sh:100) |
| deinit 跨线程清理 | ❌ 未动 | 低危，可接受 |
| staging 清理 | ⚠️ 部分 | 脚本只删 `extracted/`，zip 与 install.sh 靠 24h prune |
| **待确认**：旧存档严格 decode | ✅ 已修 | `decodeIfPresent` 保守默认（availability→`.missing`，createdAt→`.distantPast`） |
| **待确认**：reload 不重置队列定时器 | ✅ 已修 | reload 现在重排 watchdog/interval |
| **待确认**：元数据全量写回覆盖并发编辑 | ✅ 已修 | `MetadataPatch` 字段级补丁（有测试） |
| **待确认**：launchAtLogin onChange 多余调用 | ⚠️ 修法有代价 | onAppear 的系统状态同步被整个移除（:284 现存同名语句是失败回退路径），开关在外部改动后不再反映真实状态（§3.5） |

**正向说明**：签名工具（`scripts/update-signing-tool.swift`）与应用端已统一为 `protocolDomain || SHA256(file)` 摘要签名方案，两侧一致，无 wire-format 失配；build-release.sh 改为默认 fail-closed（无 key 拒绝出包，`WALLPAPERMAC_ALLOW_UNSIGNED=1` 显式放行）是合理决策——因为应用端策略是 `.required`，发布无签名的包必然装不上。

---

## 三、新引入的问题

### 3.1 [高危] 心跳回调线程错误 —— 看门狗在首帧后实际失明

**位置**：[WallpaperVideoStreamController.swift:212](../../../Sources/WallpaperMac/WallpaperVideoStreamController.swift:212)（`onFrameProgress?()`）→ [WallpaperManager.swift:877](../../../Sources/WallpaperMac/WallpaperManager.swift:877)（`noteVideoFrameProgress`）→ [WallpaperManager.swift:908](../../../Sources/WallpaperMac/WallpaperManager.swift:908)（`scheduleQueueTimer`）

**机制**：`produceFrames` 运行在 `frameQueue`（GCD 串行后台队列，:21）——由 `displayLayer.requestMediaDataWhenReady(on: frameQueue)` 驱动。心跳在该线程**同步**调用 `@MainActor` 的 `noteVideoFrameProgress`（对比：同文件 `notifyPlaybackCompleted`（:255）正确地经过 `DispatchQueue.main.async`）。后果：

1. **数据竞争**：`currentSessions`、`bindings`、`queueLibrary`、`queueItems`、`queueTimers` 的读写发生在后台线程，与主线程的 `advanceQueue`/`stopQueue`/`present` 并发。Swift 字典非线程安全，存在崩溃/损坏风险。
2. **看门狗失明（确定性）**：`Timer.scheduledTimer` 在 GCD 工作线程上创建——该线程的 run loop 从不运行，**定时器永远不会触发**。首帧心跳还把主线程武装的 watchdog 从 `queueTimers` 里 `invalidate()` 掉（跨线程 invalidate 本身也是未定义行为），换成这个死定时器。此后管线卡死只能等 4 小时硬上限（[WallpaperManager.swift:864](../../../Sources/WallpaperMac/WallpaperManager.swift:864)）。
3. **附带**：即使修好线程，每帧重建 Timer（每秒 30–60 次/显示器）也是不必要的开销。

**触发**：任何"视频播完切换"队列里的视频开始出第一帧即触发；崩溃风险在高帧率 + 队列切换并发时累积。

**修复建议**：
- 与 `notifyPlaybackCompleted` 一致，心跳经 `DispatchQueue.main.async`（或 `Task { @MainActor … }`）回到主 actor；
- 续期改为延长既有定时器 `fireDate`（或 ≥1 秒节流），不要逐帧重建。

### 3.2 [中危] 迁移修复对旧迁移用户的覆盖回归

**位置**：[WallpaperStore.swift:166-228](../../../Sources/WallpaperMacCore/WallpaperStore.swift:166)

**机制**：新协议以 marker/plan 判定迁移是否完成；"legacy 存在且无 marker/plan"时**无条件**从 legacy 重新生成并覆盖现代文件。但**旧版（已发布）迁移成功后不删 `display-queues.json` 也不写 marker**（旧代码只在现代两文件都缺失时才迁移）。于是：

- 用旧版完成过迁移、之后编辑过队列/绑定（UUID、名称、绑定关系都可能变化）的用户，升级后**首次加载即被回滚到迁移时刻的状态**，编辑全部丢失，且旧 legacy 文件被 `commitMigration(removingLegacy: true)` 删除、无法找回。
- 次要问题：legacy JSON 损坏时 `decode` 抛错会让 `playbackQueues()`/`displayPlaybackBindings()` 整体失败（旧代码此时不碰 legacy），WallpaperManager 退回默认队列后一次持久化即可覆盖现代文件。

**修复建议**：legacy 存在时先 `validatesModernQueueFiles()`（已在 :266 实现）：通过则只写 marker 并退役 legacy、**不重生**；仅在现代对不完整时才走生成路径。legacy decode 失败应降级为"跳过迁移"而非整体抛错。

**测试缺口**：`testMigrationResumesFromPlanAfterPartialWrite` 实际删除了 plan 文件，测的是"无 plan 从 legacy 重生"；`resumeMigrationFromPlan` 的真实 plan-续跑路径无测试；也没有"现代对完好 + legacy 残留应保留现代文件"的用例——后者正是本回归的场景。

### 3.3 [中危] `ThumbnailCache.inflight` 内存泄漏

**位置**：[ThumbnailCache.swift:27,36](../../../Sources/WallpaperMacCore/ThumbnailCache.swift:27)

**机制**：解码完成的 NSImage 写入 `inflight[key]` 后永不清除（只有 `removeAll`），该字典不受 NSCache 的 `countLimit = 256` 约束。浏览大图库（数千项）后，所有解码位图（640px 缩略图每张约 0.5–2MB）常驻内存，可达数百 MB 至 GB 级。另外 `inflight` 写入发生在解码**之后**，对并发去重无效——两个线程同时 miss 会各解码一次。

**修复建议**：直接删掉 `inflight`（单飞去重可选：需要的话在锁内先放占位、解码后替换），或用 NSCache 承载全部缓存。`isPortrait` 可优先走 `ImageDimensions`（只读头，不解码像素）。

### 3.4 [中低] 孤儿资源清理是 no-op

**位置**：[WallpaperStore.swift:773](../../../Sources/WallpaperMacCore/WallpaperStore.swift:773)

`cleanupOrphanedManagedAssets` 用 `name.firstIndex(of: "-")` 取 UUID 前缀，但 UUID 字符串本身含短横线（8-4-4-4-12），前缀只有前 8 位十六进制，`UUID(uuidString:)` 恒为 nil → 每个条目都 `continue`，清理从未发生。配套的"先写索引后删文件、失败记 orphan"善后因此落空。修复：取前 36 字符解析 UUID。无相关测试。

### 3.5 [低危] 其他新问题与残留

1. **注释与实现相反（最值得警惕）**：[UpdateSignature.swift:66-67](../../../Sources/WallpaperMacCore/Update/UpdateSignature.swift:66) 写着 "Streaming hash so multi-hundred-MB zips never sit in memory"，下一行却是 `Data(contentsOf: url)` 整读入内存；`sign(fileAt:)` 同样整读（签发侧影响构建机，验证侧影响所有用户安装时的峰值内存）。修法：分块流式 SHA-256（`UpdateArtifactVerifier.sha256Hex(ofFileAt:)` 已有同型实现可改为产出 raw digest）。
2. **登录开关陈旧**：SettingsWindowController 的 `onAppear` 移除了 `launchAtLogin = LoginItemService.isEnabled` 同步（现 :284 的同名语句是 `updateLaunchAtLogin` 失败回退路径），外部修改登录项后设置开关显示旧值。
3. **下载进度丢失**：见 §2/#7。
4. **ProcessRunner**：超时 SIGTERM 后无 SIGKILL 兜底；`FileHandle(forWritingTo:)` 抛出的非 `Failure` 错误裸露传播（仍 fail-closed，仅信息不统一）。
5. **staging 残留**：安装脚本只删 `extracted/`，zip 与 install.sh 依赖 24h prune。
6. **smoke 脚本**：回退路径仍硬编码 `v0.2.5`，且全程不验证签名（`SIG_URL` 仅打印）。

---

## 四、测试覆盖评估

**新增 8 项**（全过）：队列整体替换保序、UniquedDictionary 首值胜出、MetadataPatch 不覆盖并发编辑、先写索引后删文件、迁移部分写入恢复、legacy 缺字段降级解码、drop 聚合保序/去重。质量总体不错，断言与实现一致。

**覆盖缺口**（按风险排序）：

| 缺口 | 对应风险 |
|---|---|
| 心跳回调的线程模型（当前测试全同步单线程，无法暴露 §3.1） | 高危 bug 漏网 |
| "现代对完好 + legacy 残留"场景 | §3.2 回归漏网 |
| `resumeMigrationFromPlan` 真实 plan-续跑 | 名实不符（测试删了 plan 文件） |
| 无尾斜杠目录 URL | 原 #11 的原始场景 |
| 孤儿清理、ProcessRunner 超时、下载进度 | §3.4/§3.5 |
| 签名 verify 的内存路径 | §3.5-1 |

---

## 五、合入建议

**必须（合入前）**
1. 修 §3.1：心跳回调 hop 到主 actor + `fireDate` 续期（一次性小改动，但决定看门狗修复是否真正生效）。
2. 修 §3.2：迁移前先信任通过校验的现代文件，legacy decode 失败降级。

**应当（尽快）**
3. 修 §3.3 `inflight` 泄漏、§3.4 UUID 前缀解析。
4. 修 §3.5-1：流式哈希 + 删掉误导注释。

**可以（随后）**
5. 低危余项：moveQueueItems 占位行、下载进度（可用 `URLSessionDownloadDelegate` 恢复）、登录开关同步、SIGKILL 兜底、smoke 脚本。
6. 补 §4 缺口测试，尤其是心跳线程与迁移覆盖场景。

---

## 附录：评审验证过程摘要

- 全部高危/中危结论均回源码逐行核实；子代理论断（迁移覆盖回归、孤儿 UUID 解析、签名整读、测试名实不符）均经二次验证后采信。
- 测试：`swift run WallpaperMacCoreTests` → 78/78 PASS；`swift build` → 通过。
- 签名方案一致性专项：应用端 `UpdateSignature.signedMessage`（`"WallpaperMac-update-v1\n" || SHA256`）与 `scripts/update-signing-tool.swift` :78-81、:106-108 逐一比对，一致。
- 评审期间未修改任何项目文件。
