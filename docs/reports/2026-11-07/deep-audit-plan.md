# WallpaperMac 深度检测与分阶段修复规划

- **报告日期**：2026-11-07
- **审查基线**：`49ed826a4ea96a55d5bab43a0e01a5d4e19b1424`
- **当前分支**：`codex/web-url-wallpaper`
- **版本文件**：`0.2.8`
- **目标**：集中追踪高风险链路的状态、失败和恢复路径，不以扩大功能范围或文件覆盖面为目标
- **实施边界**：检测阶段只读；随后按本规划启动阶段 0 与部分阶段 1 修复（见第 10 节）。未重新引入登录页兼容、未合并其他分支、未提交、未推送、未发布

---

## 0. 方法、证据等级与严重度

### 0.1 深入审查范围

1. **数据完整性**：导入、删除、重定位、库切换、队列/绑定持久化和旧数据迁移。
2. **播放生命周期**：每屏队列调度、暂停/恢复、热插拔、AVPlayer/ffmpeg 进度与退出。
3. **WebKit 边界**：本地文件授权、远程导航、外部浏览器、鼠标语义、暂停与渲染进程恢复。
4. **更新与发布**：弱网下载、校验、替换安装、回滚、多实例、ZIP/DMG/签名清单一致性。

候选问题需要给出具体前置条件、调用顺序、代码行和可观察后果。独立复核可以确认、降级或驳回初审结论；单次探针、双重复核和真实 App 验证在文中分开描述。

### 0.2 严重度

- **P0**：无条件或极易触发的大规模数据破坏、远程代码执行等；本轮未发现此类结论。
- **P1**：可导致用户数据/配置丢失、应用不可用、持续资源消耗或明显越界副作用，应优先处理。
- **P2**：需要特定条件的功能错误、恢复缺口或发布可靠性问题，应在对应模块验收前处理。
- **P3**：测试、文档或维护性问题，不单独作为产品故障。

“P1/P2”是修复优先级，不代表已经在所有机器或所有用户场景中复现。

---

## 1. 本地实测结果

### 1.1 构建、核心测试与模板

| 检查 | 实际结果 | 解释边界 |
|---|---|---|
| `swift build` | 通过 | 当前 App、Core 和测试目标可编译 |
| `swift build -c release` | 通过 | 不证明打包、签名或安装成功 |
| `swift run WallpaperMacCoreTests` | 95 次执行全部通过 | 注册表中同一 HEVC 函数登记两次，实际为 94 个不同测试函数 |
| 普通核心测试额外重复 20 轮 | 20/20 退出码为 0 | 未发现普通运行下的间歇性失败 |
| `validate-web-wallpaper-template.sh` | 通过 | 只验证模板结构与离线依赖约束 |
| `git diff --check` | 通过 | 不表示行为正确 |

测试注册位置：`Sources/WallpaperMacCoreTests/main.swift:708` 与 `:741` 均调用 `testVideoContainerCompatibilityNormalizesRealHev1Entries`。因此“95 项”是执行次数，不应作为 95 个独立行为场景理解。

### 1.2 真实桌面与内存回归

在重新执行 `package-release.sh` 后，以下脚本均以退出码 0 完成：

- `smoke-app.sh`：App 存活，无新增 WallpaperMac 崩溃报告。
- `player-runtime-test.sh`：图片、H.264 视频、本地网页均进入 applied；视频像素检查通过。
- `web-wallpaper-interaction-test.sh`：通过，但只验证交互窗口层级，不发送真实鼠标点击。
- `queue-memory-regression.sh`：首次及额外三轮均通过；窗口数量和 RSS 未出现持续上升趋势。
- `video-codec-runtime-test.sh`：AV1 流式解码、非黑帧和外部引用不改写均通过。
- `video-stream-memory-regression.sh`：首次及额外三轮均通过。

这些结果说明**正常资源、当前脚本和现有阈值下的路径稳定**，不能覆盖暂停跨定时器、异常 ffmpeg 退出、真实多屏热插拔、远程网站重定向或 WebContent 崩溃。

本轮机器只有一台在线显示器，未形成真实双屏验证。测试结束后没有遗留测试 App 进程。

### 1.3 核心代码覆盖率

通过 `swift build --enable-code-coverage --product WallpaperMacCoreTests`、运行测试并用 `llvm-profdata` / `llvm-cov` 汇总，仅统计 `WallpaperMacCore` 实现文件：

| 指标 | 覆盖率 |
|---|---:|
| Regions | 68.93% |
| Functions | 73.64% |
| Lines | 77.68% |

关键空白：

| 文件 | 行覆盖率 | 影响 |
|---|---:|---|
| `WallpaperStoreWorker.swift` | 0% | 测试主要直接调用同步 Store，没有经过应用实际使用的 actor 边界 |
| `ThumbnailCache.swift` | 0% | 缓存键、文件变更和失败回退未被核心测试触达 |
| `DisplayPlaybackBinding.swift` | 58.54% | 每屏状态归一化仍有多条路径未覆盖 |
| `PlaybackQueue.swift` | 68.95% | 队列编辑、覆盖项和边界组合并不完整 |
| `UpdateInstaller.swift` | 71.43% | 正常/异常安装的真实文件系统结果覆盖不足 |

覆盖率不包含 App target，不能解释为整个应用的 UI/播放覆盖率。规划不以追求 100% 为目标，而是先覆盖本轮确认的失败路径。

### 1.4 Thread Sanitizer

对核心测试启用 TSan 后，首轮报告 `UpdateDownloadMockURLProtocol` 的分块计时器在以下位置读写 `chunkOffset` 存在数据竞争：

- `Sources/WallpaperMacCoreTests/main.swift:1455`
- `Sources/WallpaperMacCoreTests/main.swift:1462`

首轮告警后，一次及连续五轮 TSan 运行未再报告；为扩大样本又执行 13 轮，其中 9 轮报告同一位置。合计 **20 轮中 10 轮出现 TSan 竞态告警**。普通模式额外 20 轮均通过。

2026-11-07 复核时再次执行 5 轮 TSan，其中 1 轮报告同一位置，确认该竞态仍可间歇复现（5 轮样本不足以重新估计频率，原始 20 轮记录保留在上文）。

当前证据指向**弱网测试桩的间歇性竞态**，不能直接推断生产下载器存在同样问题。它不是每次必现，但扩大样本后出现频率较高，会显著降低弱网测试的可信度，应在扩展故障注入前修复。另有 `main.swift:2420` 的未使用局部变量编译警告。

---

## 2. 验证边界

- 未访问真实外部网站；远程 URL 的存储测试和本地 WebKit 探针不等于线上网站验收。
- 未重新引入或评估登录/OAuth 弹窗兼容。
- 未修改真实 `/Applications` 中的 App；更新复现使用临时目录和假 App。
- 未读取更新签名私钥，未执行 GitHub Release、推送或版本发布。
- 未完成真实双屏、外接卷断开、睡眠唤醒、CGEvent 鼠标序列和 WebContent 主动终止。
- 历史报告仅用于定位背景，所有当前问题以基线代码和本轮探针为准。

---

---

## 3. 已确认问题清单

下列问题均以当前基线代码为依据。**“双重确认”指两个独立复核实例都给出 `confirmed`**；少数条目因复核实例失败只有一次确认，会在“证据”中注明。严重度采用复核后的评级；有分歧的条目会标明。

### 3.1 数据完整性与状态一致性

#### D1. 损坏的队列/绑定 JSON 被降级为默认状态，下一次普通操作会覆盖原文件

- **严重度**：P1
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:705-730`、`:809-813`；`Sources/WallpaperMacCore/WallpaperStore.swift:104-137`
- **触发链**：
  1. `loadQueues()` 把 `playbackQueues()` / `displayPlaybackBindings()` 的任意解码错误替换为默认队列和空绑定，且没有“加载失败、禁止回写”的标记。
  2. 用户随后新建/编辑队列、停止队列或执行任何 `persistQueues()` 路径。
  3. 内存中的降级状态被原子写回，覆盖原本可修复的损坏文件；队列定义或全部显示器绑定因此不可逆丢失。
- **后果**：静默、不可逆的用户配置丢失；原子写只保证单文件不被截断，反而让默认状态成为“权威”数据。
- **修复要点**：区分“文件不存在”和“存在但读取/解码失败”；失败时保留原字节、禁止自动回写并暴露恢复入口；`persistQueues` 必须传播错误；队列与绑定需要共同恢复点或备份。
- **回归测试**：`marker` 已存在时分别损坏 queues/bindings → `configure` → `createQueue`，断言两份文件字节不变且操作报错。

#### D2. 库切换后旧 worker 的完成回调可覆盖新库视图，并可能删除新库同 UUID 资源

- **严重度**：P1
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/MainView.swift:642-667`、`:717-737`、`:885-903`；`Sources/WallpaperMacCore/WallpaperStore.swift:623-667`
- **触发链**：
  1. 库 A 的大型导入/删除/重定位仍在执行（`FileManager.copyItem` 等同步工作提供真实窗口）。
  2. 用户切换到库 B，B 的 reload 先完成。
  3. A 的 Task 完成后无条件 `applyMutationSnapshot`，把 A 的快照写到当前 ViewModel；此时 `libraryURL`、worker 和 `WallpaperManager` 已属于 B。
  4. 若 A/B 是副本并含相同 UUID，用户在这张旧视图上删除项目时，删除会按 UUID 命中 B 的真实记录和托管资源。
- **后果**：轻则旧库内容错显在 B；重则删除 B 中用户未选择的资源，属于跨库数据破坏。
- **修复要点**：每次库选择生成单调 session/generation；所有异步 mutation（import/remove/assign/relocate/apply/favorite/metadata）在每次 `await` 后校验 session；切库后立即隔离旧列表或禁止基于旧列表的操作。
- **回归测试**：可注入延迟 worker，确定性安排“A 导入未完成 → 切 B → B reload 完成 → A 回调”，断言 B 的状态、索引、资源、队列与显示分配均不变。

#### D3. 删除先提交显示绑定和队列，主索引失败或中途崩溃会留下半删除状态

- **严重度**：P1
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/MainView.swift:885-903`、`:557-575`；`Sources/WallpaperMac/WallpaperManager.swift:200-207`、`:755-779`、`:809-813`；`Sources/WallpaperMacCore/PlaybackQueue.swift:217-220`
- **触发链**：
  1. 删除正在显示且属于队列的项目 X。
  2. `WallpaperManager.removeWallpaperIDs` 先清显示分配、再次持久化队列并删除 X 的成员与 `itemIntervalOverrides`。
  3. 之后 `WallpaperStore.remove` 才读取/写入 `wallpapers.json`；若读取或写入失败，或进程在两段之间终止，前面写入不会回滚。
- **后果**：重启后 X 仍在主索引中，但显示分配已清空、队列成员和单项目时长永久丢失；没有启动时对账或恢复入口。
- **修复要点**：删除做成可恢复提交：要么先提交主索引再清理引用（悬空 ID 由现有 missing/placeholder 机制容忍），要么先落盘删除意图并在启动时幂等完成/回滚。任何中间状态都不得丢弃仍属有效项目的队列配置。
- **回归测试**：在 assignments、queues、bindings、主索引每一步后注入失败/崩溃，恢复后断言全删或完整保留，尤其保留 `itemIntervalOverrides`。

#### D4. 非空旧队列文件 + 空现代绑定被判定为“迁移完成”，旧文件被退休

- **严重度**：P1/P2 边界（两位复核均确认触发；一位评 P1、一位评 P2）
- **证据**：双重确认（严重度有分歧）
- **位置**：`Sources/WallpaperMacCore/WallpaperStore.swift:194-196`、`:287-306`、`:272-282`
- **触发链**：`display-queues.json` 非空且含 `currentIndex`/`isEnabled`，同时 `playback-queues.json` 有效、`display-playback-bindings.json` 为 `[]`，且无 marker/plan。`validatesModernQueueFiles()` 对空数组的循环“空真”通过，迁移直接提交并退休 legacy。旧版两阶段迁移的中间状态也可能产生这一前置状态。
- **后果**：每屏活动队列、播放进度和启用状态不会进入现代绑定；唯一保留它们的文件不再被读取。`.migrated` 备份仍在，因此不是物理删除，但应用无恢复入口。
- **修复要点**：legacy 可解码且非空时，空/缺失现代绑定不得满足“完整现代对”；保留 plan-first 顺序和用户后来编辑的现代队列。歧义状态保留 legacy 并提供恢复/合并。
- **回归测试**：`legacy 非空 + bindings=[]` 必须生成完整绑定，而不是写 marker 退休 legacy；同时保留“有 legacy 时有效现代绑定优先”的现有用例。

#### D5. 网页项目重定位丢失原嵌套入口，静默改播 `index.html`

- **严重度**：P2
- **证据**：双重确认 + 两种存储模式的临时 Core 探针复现
- **位置**：`Sources/WallpaperMacCore/WallpaperStore.swift:549-558`、`:590-606`、`:857-860`
- **触发链**：导入时选择 `pages/home.html` → 原目录丢失 → 重定位，判断原目录是否为目录时读取已缺失路径的 `resourceValues` 得到 `nil`，无法计算相对入口；随后 `webEntryURL` 优先选 `index.html`。
- **后果**：操作显示成功、`availability=available`，但入口被持久化改写，用户看到另一个页面；`managedCopy` 和 `externalReference` 都受影响。
- **修复要点**：导入时持久化相对入口路径并做旧数据兼容；重定位时仅用旧 URL 做带边界校验的纯字符串推导；目标入口缺失时明确报错或让用户选择，不能静默改选。
- **回归测试**：删除原资源、重启式重解码、替换目录同时含 `index.html` 与原嵌套入口，断言返回和持久化入口均为原 `pages/home.html`。

### 3.2 播放生命周期与队列调度

#### P1. 暂停/系统挂起没有统一的队列调度协议

- **严重度**：P1
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:121-131`、`:587-625`、`:851-875`、`:918-961`、`:560-572`
- **触发链 A（系统暂停仍切换）**：固定间隔队列运行中触发电池/全屏暂停；`setSystemSuspended` 只暂停播放器，不改队列 timer，也不禁用绑定；下一个 tick 仍 `advanceQueue`，新控制器以 suspended 状态创建，恢复后显示的是下一项。
- **触发链 B（手动暂停后永久停队列）**：固定间隔队列手动暂停后跨越一次 tick；旧 timer 因 `isEnabled=false` 进入 `stopQueue`，移除普通计时器和硬截止计时器；恢复只改状态与播放器，不重建计时器，队列从此不再推进。
- **后果**：系统节能策略无法保护队列位置；用户“恢复动态壁纸”后界面显示启用但实际永不切换。
- **修复要点**：拆分“用户希望队列运行 / 手动播放开关 / 系统 suspended”；集中 `reconcileScheduling(displayID)`；所有暂停冻结固定间隔、watchdog、硬截止时间并保存剩余时间；所有恢复走同一入口；timer 回调校验 session/generation。
- **回归测试**：可控时钟覆盖系统暂停跨过 interval/watchdog/hard deadline、手动暂停跨 tick 再恢复、恢复后只切换一次、暂停期间 `currentIndex` 不变。

#### P2. ffmpeg 退出处理不区分正常 EOF 与异常退出

- **严重度**：P1（正常 EOF 尾帧丢失单独看接近 P2）
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/WallpaperVideoStreamController.swift:227-253`、`:268-299`、`:70-85`
- **触发链 A（重启风暴）**：AV1/VP9 或不可播放视频走 ffmpeg；默认 `loops=true`；ffmpeg 因解码错误/不可用可执行文件每次非零退出；`processDidTerminate` 不读退出状态，无退避/上限地立即再次 `startProcess`。暂停只停止取帧，不阻止重启。
- **触发链 B（尾帧丢失）**：正常 EOF 时 `terminationHandler` 可能先于读取侧消费完管道，清空 `bufferedData`；读取侧只剩最后 1 字节，不足一帧，末帧被丢弃并提前触发完成/循环。
- **后果**：持续子进程创建与资源消耗；视频末帧偶发丢失或提前推进。
- **修复要点**：状态机（running/draining/exited/failed/tornDown）；正常退出由读取侧 drain 到 EOF 再决定完成/循环；非零退出进入有上限的指数退避或失败态并上报；暂停/teardown 不重启；teardown 幂等且零完成回调。
- **回归测试**：注入假进程/管道：立即非零退出时最大进程数、暂停后零新增、EOF 分段写入的完整帧数、teardown 后零回调。

#### P3. AVPlayer 未知时长被 60 秒 watchdog 误判为卡死

- **严重度**：P2
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:857-875`、`:918-924`、`:1560-1593`；`Sources/WallpaperMacCore/PlaybackQueue.swift:267-282`
- **触发链**：`videoCompletion` 队列、可原生播放的 H.264、`metadata.durationSeconds` 为 `nil`/非法。启动后 watchdog 按 60 秒；原生 AVPlayer 路径没有周期时间观察者或帧心跳；60 秒后 `advanceQueue` 无条件切换健康视频。启动后的元数据 enrichment 不会重算当前 session。
- **后果**：长视频在第 60 秒被提前切走。
- **修复要点**：AVPlayerItem ready 后加载实际 duration 并重算；用 `currentTime` 前进 + `timeControlStatus` 作为心跳；暂停/挂起冻结检测；enrich 到达后更新当前 session。
- **回归测试**：播放器替身 + 可控时钟：时间持续前进超过 60 秒不切换；时间冻结才切换；enrich 后不误切。

#### P4. 热插拔 reapply 不是幂等协调

- **严重度**：P2
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:243-256`、`:259-279`、`:531-557`、`:865-871`
- **触发链 A**：任意屏幕参数通知触发全量 `reapply`；所有仍连接且 enabled 的显示器无条件 `startQueue` → `apply` → 新 session/控制器/播放器，播放位置和固定间隔归零。
- **触发链 B**：断屏只失效 `queueTimers`，未清 `hardDeadlineTimers` 和 `currentSessions`；4 小时硬截止到达时因无连接显示器 `stopQueue` 并持久化 `isEnabled=false`，重连后队列不自动恢复。
- **后果**：无关屏幕变化重启所有视频；长时间断屏后重连丢失队列自动播放。
- **修复要点**：按 displayID 做 diff；未变化的屏不重建；断屏统一清理两类 timer 与 session 但不改用户 enabled；重连只恢复目标屏；timer 回调校验 session。
- **回归测试**：假 controller factory + 假时钟：无关屏变化不增加 A 的 session；断屏两类 timer 都取消；超过 4 小时重连仍 enabled。

#### P5. 删除当前播放项会先停用队列，后续“是否重启”永远读到 false

- **严重度**：P2
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:200-207`、`:560-572`、`:755-787`
- **触发链**：队列 [A,B,C] 正在显示 B → 从图库删除 B → `clear` 先 `stopQueue` 把 `isEnabled/isPlaying` 写成 false 并持久化 → 后续 `removeWallpaperIDsFromQueues` 读取 `wasEnabled=false`，不重启；A、C 仍可用但显示器空白，重启后也不会恢复。
- **后果**：删除当前壁纸后队列永久停用；共享同一队列的其他屏行为不一致。
- **修复要点**：删除前按屏快照 enabled/current item/queue；先统一更新队列成员，再按稳定 itemID 选后继；仅对删除前已启用且仍有可用项的屏重启；中间状态不持久化为用户停用。
- **回归测试**：[A,B,C] 删 B 后 D 继续 C；删非当前项不重建 session；删最后可用项才清屏停用；多屏共享队列矩阵。

### 3.3 WebKit 边界与网页生命周期

#### W1. 页面脚本无需真实点击即可反复唤起默认浏览器

- **严重度**：P1
- **证据**：双重确认 + 两个独立 WKWebView 探针（无用户输入 3 次 `a.click()` → 3 次 `.linkActivated` 回调）
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:1641-1653`
- **触发链**：远程或本地页面在 `onload`/`setInterval` 中对 `target="_blank"` 链接调用 `click()`；WebKit 仍上报 `.linkActivated`；当前代码只校验该类型和 HTTP/HTTPS，直接 `NSWorkspace.shared.open`。不检查交互开关、`isPlaying`、系统挂起，也没有频率限制。
- **后果**：即使用户关闭“壁纸点击效果”或暂停壁纸，网页仍可在后台持续唤起浏览器、打开大量标签页，属于未经用户触发的外部应用副作用和资源消耗。
- **修复要点**：默认拒绝无原生用户激活的新窗口导航；把 opener 抽象为可注入依赖；只有“交互开启 + 正在播放 + 未挂起 + 最近一次原生 mouseUp 的一次性授权（绑定目标 URL）”才放行；频率限制作为纵深防御。
- **回归测试**：自动 `a.click()` 必须 0 次 opener；真实点击 `target=_blank` 恰好 1 次；交互关闭/暂停/挂起均为 0；授权单次消费、短时过期。

#### W2. 单个 HTML 的托管导入会隐式复制整个父目录

- **严重度**：P1/P2 边界（复核者分别评 P1、P2；默认路径越界副作用明确）
- **证据**：双重确认 + Store 探针复现（无关文件、隐藏文件、嵌套目录均被复制）
- **位置**：`Sources/WallpaperMacCore/WallpaperStore.swift:389-400`、`:409-423`；`Sources/WallpaperMac/WallpaperManager.swift:1485-1490`
- **触发链**：默认“复制到应用库”下只选择 `~/Documents/clock.html`；`managedCopySourceURL` 被改为父目录并整棵复制到 `Assets/<UUID>-Documents`，无关文档、隐藏文件和大型子目录一并长期保留；确认页只显示入口文件名。外部引用时 `allowingReadAccessTo` 同样是父目录，而不是所选文件。
- **后果**：意外的磁盘占用与隐私范围扩大；用户以为只导入了一个文件。未证明可任意读取文件字节或自动外传。
- **修复要点**：区分“单个 HTML 文件”和“显式选择的项目目录”；单文件只复制该文件、只授权该文件；需要相对资源时要求用户显式选择项目根；确认页展示根路径、递归文件数和估算大小。
- **回归测试**：单文件导入后 Assets 中只有该文件；无关 sibling/隐藏 sentinel/嵌套目录均不存在；显式目录项目仍保留现有资源兼容；`readRoot` 决策函数覆盖两种模型。

#### W3. 网页“暂停”只是瞬时 DOM 命令，后续媒体与脚本可继续运行

- **严重度**：P2
- **证据**：双重确认
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:1431-1446`、`:1611-1622`、`:1477-1497`
- **触发链**：暂停或电池/全屏挂起只对当时存在的 `video,audio` 各执行一次 `pause()`；页面随后 `setTimeout` 调用 `play()`、动态插入新媒体、或继续 rAF/定时器/WebAudio，宿主不会再次纠正。`didFinish` 在暂停态甚至不发送 pause。UI 依据布尔状态显示 paused，与实际媒体状态脱节。
- **后果**：暂停后仍可能播放/出声（取消静音时），电池/全屏策略无法兑现资源暂停预期。
- **修复要点**：`didFinish` 无条件按最新状态落实 play/pause；用 document-start 门禁或 DOM 观察覆盖后增媒体与再次 `play()`；若要停止整个 WebContent，需产品层面定义快照/销毁重建；只承诺媒体暂停则同步修改 UI 文案。
- **回归测试**：加载前暂停、挂起中完成导航、didFinish 后动态媒体调用 play，断言 paused 且 currentTime 不增长；恢复后可播放。

#### W4. 鼠标桥在任意 mouseUp 目标上强制 click

- **严重度**：P2
- **证据**：双重确认
- **位置**：`Sources/WallpaperMacCore/WebMouseEventScript.swift:15-33`；`Sources/WallpaperMac/WallpaperManager.swift:1314-1352`
- **触发链**：交互开启后，在按钮 A 按下、拖到按钮 B 松开；宿主不保存按下目标，`mouseUp` 对 `elementFromPoint` 命中的 B 无条件 `click()`。若 B 是 `target=_blank`，还会串联外部浏览器。
- **后果**：跨目标拖动误激活按钮/链接；允许拖选后误导航。
- **修复要点**：优先让 WKWebView 原生处理鼠标事件；若保留 JS 桥，记录 mousedown 目标并在合法共同目标上激活，处理拖动阈值、取消、修饰键与 `defaultPrevented`。
- **回归测试**：真实 CGEvent 按下/松开同目标、跨目标、拖出窗口；跨目标不得激活 B。

#### W5. WebContent 进程终止没有恢复路径

- **严重度**：P2
- **证据**：双重确认 + SDK 回调契约核对
- **位置**：`Sources/WallpaperMac/WallpaperManager.swift:1616-1668`（未实现 `webViewWebContentProcessDidTerminate`）
- **触发链**：网页 `didFinish` 后渲染进程崩溃/被系统回收；该事件不进入 `didFail`/`didFailProvisionalNavigation`，错误标签保持隐藏，没有 reload/重建；单独应用的网页会一直空白，直到用户手动“重新加载”或重新应用。
- **后果**：核心内容持续丢失，无自动恢复；队列场景可能在下一次切换偶然恢复。
- **修复要点**：实现终止回调；显示明确失败状态；按 PlaybackSession 预算做有上限退避重载/重建；加载超时；teardown/session 替换取消旧任务；预算耗尽保留错误状态，不改写资源可用性。
- **回归测试**：真实终止 WebContent 后断言可见失败状态并在预算内恢复；连续终止有上限；teardown 后无迟到加载。

### 3.4 更新与发布

#### U1. 复制失败后的回滚会把旧版移进残缺的新包，且替换过程没有中断恢复

- **严重度**：P1
- **证据**：双重确认 + 真实 `/usr/bin/ditto` 在临时目录复现
- **位置**：`Sources/WallpaperMacCore/Update/UpdateInstaller.swift:192-224`
- **触发链**：脚本先把 `TARGET_APP` 移到 `.previous`，再 `ditto` 复制；`ditto` 失败时已创建部分目标目录，失败分支直接 `mv "$TARGET_PREVIOUS" "$TARGET_APP"`。macOS `mv` 在目标目录存在时会把旧包嵌套进去（实测旧包位于 `Target.app/Target.app.previous`），标准路径只剩残缺新包。脚本也没有 trap/事务记录；在 `mv` 后、复制完成前断电或终止会留下缺失/半复制应用，没有自动恢复入口。
- **后果**：用户确认更新后，应用可能无法从标准入口启动，需要手工恢复或重装。
- **修复要点**：最低限度在回滚前显式删除残缺目标并校验恢复后的旧包；完整方案先把已验证新包复制到同文件系统独立临时 sibling，完成结构与签名校验后再交换；持久化安装事务，启动或独立恢复器可幂等完成/回滚。
- **回归测试**：真实执行安装脚本，注入“创建部分目标后失败”的 `ditto`，断言原路径逐文件恢复旧包、无嵌套 `.previous`；再测复制中途终止后的恢复。

#### U2. 以 `open` 的退出码判定启动成功，新应用崩溃时不会自动回滚

- **严重度**：P2
- **证据**：双重确认
- **位置**：`Sources/WallpaperMacCore/Update/UpdateInstaller.swift:210-224`
- **触发链**：新包通过哈希、签名和版本检查，但启动期崩溃（缺动态库、架构、初始化异常）。`/usr/bin/open` 只表示 LaunchServices 受理请求，返回 0 后脚本删除 staging 并退出；自动恢复分支不可达，坏包留在标准路径，`.previous` 仅作为手动回滚句柄。
- **后果**：更新后应用不可用，需要人工恢复。
- **修复要点**：新实例在关键初始化完成后写入一次性安装 token 确认；脚本有界等待，超时/无效 token/进程退出则清理坏包、恢复并重启旧版；静态预检（codesign、可执行文件、架构、动态库闭包）作为前置防线，不能替代健康确认。
- **回归测试**：真实执行脚本，令 `open` 返回 0 但新包立即退出/永不确认，断言恢复旧版；正确确认时才提交。

#### U3. 并发防护仅限单个 `UpdateService`，多实例安装共享并删除彼此的备份

- **严重度**：P2
- **证据**：单次独立确认 + 初审代码证据（第二个复核实例因额度失败）
- **位置**：`Sources/WallpaperMacCore/Update/UpdateInstaller.swift:170-203`；`Sources/WallpaperMac/UpdateService.swift:50-57`
- **触发链**：`open -n` 启动两个同路径实例并同时确认更新；两者通过各自 `isBusy`，使用不同 staging，却共享固定 `TARGET_APP` 和 `TARGET_APP.previous`；B 无条件 `rm -rf` A 刚建立的备份，可能同时 `ditto` 到同一路径。
- **后果**：备份丢失、混合复制或错误提交；现有 `alreadyInstalling` 错误从未使用。
- **修复要点**：以标准化目标路径为键的跨进程独占锁，覆盖准备、交换、健康确认；父进程退出后由 detached helper 持有；脚本在破坏性操作前复核所有权与目标代际。
- **回归测试**：两个脚本并发、不同 staging/payload，断言只有一个所有者、旧包始终可恢复、最终包来自单一 payload。

#### U4. 文档化发布顺序会让 DMG 缺席 SHA256SUMS，并重新打包已签 ZIP 之外的 App

- **严重度**：P2
- **证据**：双重确认
- **位置**：`scripts/build-release.sh:19-65`；`scripts/build-dmg.sh:23-28`；`docs/development/build-and-release.md:78-84`
- **触发链**：按文档先 `build-release.sh`（生成 ZIP、签名和只含 ZIP 的 SUMS），再 `build-dmg.sh`（再次 `package-release.sh` 重建 App）；最终 DMG 不在清单中，ZIP/DMG 可能来自不同构建快照，而两者仍各自“有效”。
- **后果**：发布清单不完整；同版本手工安装包与自动更新包可能内容漂移。
- **修复要点**：单一发布入口：只打包一次并冻结 App，ZIP 和 DMG 从同一快照生成；所有产物完成后统一生成 SUMS，再对最终 ZIP 签名/复验；`build-dmg.sh` 不隐式重建或必须同时重建全部产物。
- **回归测试**：空 `dist` 跑完整入口，断言 SUMS 同时含 ZIP/DMG、签名对应最终 ZIP、ZIP 与 DMG 内 App 内容摘要一致。

#### U5. 线上产物冒烟可能假阳性

- **严重度**：P2
- **证据**：单次独立确认 + 初审代码证据（第二个复核实例因额度失败）
- **位置**：`scripts/update-artifact-smoke.sh:81-154`
- **触发链**：远程 ZIP 下载失败时回退本地；本地哈希不符仍打印 PASS；缺少 `.sig` 只打印 WARN；最终无条件输出 `UPDATE_ARTIFACT_SMOKE_PASSED` 并退出 0。应用默认策略 `required` 会拒绝这些发布。
- **后果**：若被当作发布门禁，会放行客户端无法更新的发布。
- **修复要点**：生产/门禁模式必须成功下载并校验远程 ZIP、必须存在且验证 `.sig`（与嵌入公钥交叉核对）；只有显式诊断模式允许降级且使用不同标记；本地 mismatch 非零退出；接入发布流程。
- **回归测试**：远程 404/中断、缺 sig、本地哈希不符、错误密钥四种情况生产模式均非零。

### 3.5 测试与文档基础设施

#### T1. 弱网测试桩存在间歇性数据竞争

- **严重度**：P2（针对测试可信度）
- **证据**：本轮实测 TSan 20 轮中 10 轮报告
- **位置**：`Sources/WallpaperMacCoreTests/main.swift:1442-1467`（`chunkOffset` 在全局队列计时器中读写）
- **后果**：弱网下载测试可能偶发不稳定，TSan 门禁不可用；当前证据只指向测试桩，未证明生产下载器有同样竞态。
- **修复**：计时器使用串行队列并加锁保护偏移，或在同一队列内调度所有状态迁移；开启 TSan 小规模回归。

#### T2. 核心测试没有覆盖应用实际使用的异步边界

- **严重度**：P2（针对测试可信度）
- **证据**：核心实现行覆盖率 77.68%；`WallpaperStoreWorker` 0%、`ThumbnailCache` 0%；测试目标只链接 `WallpaperMacCore`
- **后果**：`LibraryViewModel`、`WallpaperManager`、`DisplayService`、`WallpaperLibraryAccess`、WebKit 交互和安装编排都没有直接测试；正常路径全绿不能证明这些层的状态与失败路径。
- **修复**：引入可注入的 worker/session、controller factory、时钟/计时器、WebKit opener、安装器工具路径；把关键编排下沉为可测试类型或增加 App 测试 target。

#### T3. 测试注册重复与警告

- **严重度**：P3
- **证据**：`main.swift:708` 与 `:741` 重复登记同一 HEVC 测试；`:2420` 有未使用变量警告
- **修复**：去掉重复登记（95 次执行 → 94 个独立函数），清理警告；文档中的“95 项”改为“94 个独立测试（95 次执行）”。

#### T4. 网页交互脚本没有真正验证点击

- **严重度**：P2（针对测试可信度）
- **位置**：`scripts/web-wallpaper-interaction-test.sh:112-137`
- **问题**：只检查窗口层级，没有发送鼠标事件，也没有断言 DOM 点击或 `NSWorkspace` 行为，却输出通过。
- **修复**：补充真实 CGEvent 与可注入 opener 的端到端用例，或明确把脚本改名为“窗口层级检查”。

#### T5. 文档与当前实现不一致

- **严重度**：P3
- **问题**：
  - `CONTRIBUTING.md`、`SECURITY.md` 和部分设计稿仍写“仅本地壁纸”，与已实现的远程 URL 冲突。
  - `README.md` 声称 GitHub Actions 自动验证，但仓库没有受 Git 管理的 `.github/workflows`。
  - 设置/更新服务的回退版本在已提交代码中仍为 0.2.7（当前未提交改动已修正，但没有提交）。
  - 历史报告中的测试数字（95/122）属于不同分支/时点，不能当作当前事实。
- **修复**：随本次规划一并更新文档；不要把历史报告改写为当前结论。

---

## 4. 分阶段修复规划

### 总原则

1. **先止损，再改造**：每个 P1 先做最小可验证修复，再考虑结构化重构。
2. **先写失败测试**：除安全/不可逆操作外，每个修复必须先有在当前代码上稳定失败的回归测试。
3. **共享根因合并处理**：删除编排、库会话、调度器各自只引入一次机制，避免多个补丁互相覆盖。
4. **不扩大功能面**：修复期间不合入另一条 0.2.8 分支，不重新引入登录/OAuth 兼容，不做全量架构重写。
5. **证据驱动评级**：报告中的 P1/P2 用于排序，不替代实机复现；修复完成后重新评估。

### 阶段总览

| 阶段 | 目标 | 主要问题 | 预估工作量 | 依赖 |
|---|---|---|---:|---|
| 0 | 建立可失败测试底座 | T1-T4、测试注入点 | 2-3 人日 | 无 |
| 1 | 防止用户数据/配置丢失 | D1-D4、D5、P5、U1 最小修复 | 5-7 人日 | 阶段 0 的 worker/session/安装测试缝 |
| 2 | 恢复播放与队列正确性 | P1-P5、W3 的宿主侧基础 | 6-8 人日 | 阶段 0 的时钟/controller/进程测试缝 |
| 3 | 收紧 WebKit 边界 | W1、W2、W4、W5 | 5-7 人日 | 阶段 0 的 opener/WebKit 测试缝 |
| 4 | 事务化更新与发布门禁 | U1 完整方案、U2-U5 | 6-8 人日 | 阶段 0 的安装器测试缝 |
| 5 | 全量验收与文档同步 | 硬件矩阵、文档、版本说明 | 2-4 人日 | 全部阶段 |

工作量是单人顺序实施的粗略估计，不含真实网站/双屏人工验收的等待时间。

---

### 阶段 0：测试底座与可观测性（必须先做）

**目标**：让后续每个修复都有稳定失败/通过的自动化证据，并消除“测试全绿但关键层零覆盖”的盲区。

**任务**

1. 修复 `UpdateDownloadMockURLProtocol` 竞态：
   - 分块计时器使用专用串行队列，`chunkOffset`/`chunkBody` 只在该队列访问，或统一加锁；
   - `stopLoading` 取消计时器并清空状态；
   - 将 TSan 核心测试（至少更新下载用例）加入本地验证命令。
2. 消除重复测试登记和未使用变量警告；把测试数量改为“独立函数数”。
3. 增加测试注入缝：
   - `LibraryViewModel`：可注入 worker/session，暴露 session token，可延迟完成；
   - `WallpaperManager`：可注入 controller factory、时钟/计时器、display 列表；
   - `WallpaperVideoStreamController`：可注入 fake process/pipe/frame sink；
   - WebKit：可注入 opener，抽离导航授权决策；
   - `UpdateInstaller`：可注入工具路径/超时/健康确认路径，能真实执行脚本。
4. 建立故障注入夹具：损坏 JSON、部分写入、写失败、进程中途退出、WebContent 终止、屏幕断开/重连。
5. 把核心测试、Release 构建和桌面冒烟串成一个明确的本地脚本入口；不要在有用户运行 App 时自动执行。

**验收**

- `swift run WallpaperMacCoreTests` 无重复登记；TSan 连续 20 轮无告警；
- 新测试缝在默认实现下不改变产品行为；
- 至少一个故障注入测试能在当前代码上稳定失败（证明测试有效）。

**不做**：不追求覆盖率数字；不把所有 App 代码迁入 Core。

---

### 阶段 1：数据完整性与防丢失（最高优先级）

**目标**：任何普通操作、I/O 失败或崩溃都不应静默丢失用户配置，也不应跨库误删资源。

**任务**

1. **D1 加载失败保护**
   - `WallpaperManager` 区分“文件不存在”和“读取/解码失败”；失败时记录错误并禁止自动回写；
   - `persistQueues` 返回 `Result`/抛错，调用方不能伪成功；
   - 队列与绑定使用共同恢复点或备份；提供“导出损坏文件/重置”的用户路径。
2. **D2 库会话（session/generation）**
   - 每次切库生成新 session；所有 mutation 捕获 session 与 worker；
   - 每个 `await` 后、修改状态/调用 Manager/新 worker 前校验；
   - 切库期间隔离旧列表，禁止基于旧列表删除/应用/重定位；
   - 明确旧导入是“继续写旧库并丢弃 UI 结果”还是协作取消；两者都必须清理半成品。
3. **D3 删除事务**
   - 推荐顺序：先提交主索引，再清理显示/队列引用；或先写删除意图并在启动时续作；
   - 删除前快照每屏 enabled/current item/queue，删除后按稳定 itemID 选后继；
   - 主索引失败时不得改动 assignments/queues/bindings；配置写失败必须可观察；
   - 启动时增加跨文件 reconciliation，容忍悬空 ID。
4. **D4 迁移校验**
   - legacy 非空且现代 bindings 为空/缺 displayID 映射时，不提交 marker、不退休 legacy；
   - 保留 plan-first 与有效现代编辑优先的现有语义。
5. **D5 网页相对入口**
   - 新记录持久化相对入口路径；旧记录在重定位时从旧 URL 做规范化字符串推导；
   - 目标入口缺失/越界时明确报错或让用户选择，禁止静默改选 `index.html`。
6. **P5 删除当前播放项**
   - 与 D3 合并实现：删除前快照、先更新队列成员、按 itemID 选后继、仅对原 enabled 屏重启。

**验收**

- 上述每条都有确定性回归测试，且在修复前稳定失败；
- 模拟写失败/崩溃后重启，所有 JSON 要么完整旧状态、要么完整新状态，不出现半删除；
- 跨库 A/B 含同 UUID 的竞争测试不删除 B 的任何资源；
- 损坏文件不会被普通 UI 操作覆盖；
- 手动重定位后入口与用户原选择一致。

**风险**：删除顺序调整会影响队列 UI 的即时反馈；需要同时更新测试和状态提示。

---

### 阶段 2：播放、队列与资源生命周期

**目标**：暂停/恢复、视频结束、异常媒体、热插拔和删除操作下，队列状态与资源生命周期一致。

**任务**

1. **统一调度协调器（P1）**
   - 状态拆分：queueDesiredEnabled / playbackWanted / systemSuspended；
   - `reconcileScheduling(displayID)` 统一 start/pause/resume/reload/advance；
   - 冻结/恢复固定间隔、watchdog、hard deadline，保存剩余时间；
   - timer 回调校验 queue/session/generation；`advanceQueue` 最终 guard。
2. **ffmpeg 状态机（P2）**
   - running/draining/exited/failed/tornDown；
   - 正常 EOF 由读取侧 drain；非零退出指数退避 + 上限 + 错误上报；
   - 暂停/teardown 不重启；teardown 幂等；旧代回调隔离。
3. **AVPlayer 心跳（P3）**
   - ready 后加载 duration；周期时间观察者 + `timeControlStatus`；
   - 时间不前进才计 stall；enrich 到达后更新当前 session；
   - 暂停/挂起冻结检测。
4. **热插拔 diff（P4）**
   - 按 displayID 比较；未变化屏不重建；
   - 断屏清理 queueTimer、hardDeadlineTimer、session，但不改用户 enabled；
   - 重连只恢复目标屏，且只创建一次。
5. **删除编排（P5）**：与阶段 1 同步完成。

**验收**

- 假时钟测试：暂停跨 tick 后恢复能继续；系统暂停期间 `currentIndex` 不变；
- ffmpeg 重启风暴测试：最大进程数受限，暂停后零新增；
- 未知时长健康视频播放 120 秒不切换；
- 无关屏变化不重建播放器；断屏 4 小时后重连仍 enabled；
- 真实桌面冒烟、播放器矩阵、队列/流内存回归继续通过。

---

### 阶段 3：WebKit 边界与网页生命周期

**目标**：网页不能在没有用户手势时产生外部副作用；导入范围与授权范围可解释；暂停和渲染崩溃有明确语义与恢复。

**任务**

1. **W1 外部导航授权**
   - 注入 opener；默认拒绝所有无原生用户激活的新窗口；
   - 一次性、短时、绑定目标 URL 的 mouseUp 授权；
   - 检查交互开启/正在播放/未挂起；频率限制；
   - 站内新窗口返回 nil，不创建未受控 WKWebView。
2. **W2 导入模型**
   - 单文件只复制与授权该文件；目录项目保留现有行为；
   - 显式选择项目根；确认页展示范围、文件数、估算大小；
   - `readRoot` 决策函数可单测。
3. **W3 暂停语义**
   - `didFinish` 无条件落实状态；
   - document-start 门禁/ DOM 观察覆盖后增媒体和再次 play；
   - 明确产品契约：只暂停媒体，还是挂起整个 WebContent；后者采用销毁/重建。
4. **W4 鼠标语义**
   - 优先原生 WKWebView 鼠标处理；
   - 若保留 JS 桥，记录 mousedown 目标，合法共同目标才激活；处理拖动/取消/修饰键。
5. **W5 WebContent 终止恢复**
   - 实现 `webViewWebContentProcessDidTerminate`；
   - 可见失败状态 + 有上限退避重载/重建 + 加载超时；
   - 预算按 session 隔离；teardown 后取消旧任务。

**验收**

- 自动 `target=_blank` 的 `a.click()` 调用 opener 0 次；真实点击恰好 1 次；
- 单文件导入后 Assets 只多出该文件；无关/隐藏/嵌套内容不存在；
- 暂停后动态媒体和再次 `play()` 不进入播放；恢复可播放；
- 跨目标拖动不激活 B；同目标只激活一次；
- 真实终止 WebContent 后自动恢复且不循环。

---

### 阶段 4：更新安装事务与发布门禁

**目标**：安装失败可恢复，多实例互斥，发布产物来自同一快照且清单完整。

**任务**

1. **U1 安装事务**
   - 最小补丁：复制失败回滚前显式删除残缺目标，恢复后校验旧包；
   - 完整方案：先复制到同文件系统独立 sibling，校验后交换；
   - 持久化事务记录 + trap；启动或独立 helper 可续作/回滚。
2. **U2 启动健康确认**
   - 一次性 token；新 App 在关键初始化后写入；
   - 脚本有界等待；超时/无效/进程退出 → 恢复并重启旧版；
   - 静态预检作为补充，不替代健康确认。
3. **U3 跨进程锁**
   - 以标准化 target 为键的独占所有权；
   - detached helper 持有；脚本破坏性操作前复核代际；
   - 竞争方返回 `alreadyInstalling`。
4. **U4 单一发布入口**
   - 打包一次、冻结 App；ZIP 与 DMG 同源；
   - 全部产物完成后生成 SUMS；签名最终 ZIP 并复验；
   - `build-dmg.sh` 不隐式重建。
5. **U5 冒烟 fail-closed**
   - 生产模式强制远程 ZIP + 哈希 + 签名（嵌入公钥交叉核对）；
   - 诊断模式显式标记；本地 mismatch 非零退出；
   - 接入发布流程。

**验收**

- 真实执行安装脚本：复制失败、`open` 0 后崩溃、多实例并发三种情况都能恢复旧版或保持完整新版；
- SUMS 同时覆盖 ZIP/DMG，签名对应最终 ZIP；
- 冒烟四种故障注入均非零，且不输出统一成功标记。

---

### 阶段 5：全量验收与文档同步

**目标**：确认修复在真实桌面、双屏、弱网和发布链上成立，并让文档与代码一致。

**任务**

1. 运行完整自动化矩阵：
   - 核心测试（含新增故障注入）+ TSan；
   - Release/Debug 构建、模板校验、`git diff --check`；
   - App 冒烟、播放器矩阵、网页交互（真实 CGEvent）、WebContent 终止、队列/流内存；
   - 安装器故障注入、发布入口 dry-run、artifact smoke 负例。
2. 真实硬件验收（必须单独记录）：
   - 双屏独立队列、拔插、分辨率变化、断屏超 4 小时后重连；
   - 电池/全屏暂停跨定时器；
   - 真实 HTTP/HTTPS 网页（含重定向、失败、渲染崩溃）；
   - 弱网/断点续传/签名失败；
   - 安装失败回滚与多实例。
3. 文档同步：
   - 更新 `CONTRIBUTING.md`、`SECURITY.md`、设计稿中的“仅本地”表述；
   - 修正 README 的 CI 与实际工作流状态；
   - 版本回退值统一到 `VERSION`；
   - 测试数量改为独立函数数；
   - 在 release notes 中如实记录已知限制。
4. 发布前检查（仅在用户明确要求发布时执行）：
   - 版本号、CHANGELOG、release notes、SUMS、签名、DMG 挂载、Gatekeeper/公证状态。

**验收**

- 所有自动化脚本通过，且失败注入用例确实覆盖对应缺陷；
- 双屏/真实网站/更新安装由人工签字确认；
- 文档不存在“已实现/未实现”矛盾；
- 发布产物版本、哈希、签名、清单一致。

---

## 5. 依赖关系与建议实施顺序

```text
阶段 0 测试底座
  ├── 1.1 D1 加载失败保护（可并行）
  ├── 1.2 D2 库会话 ──┬── 1.3 D3 删除事务 ── 1.4 P5 删除当前项
  │                   └── 1.5 D5 网页入口
  ├── 1.6 D4 迁移校验
  ├── 2.1 P1 统一调度 ── 2.2 P2 ffmpeg 状态机
  │                   ├── 2.3 P3 AVPlayer 心跳
  │                   └── 2.4 P4 热插拔 diff
  ├── 3.1 W1 外部导航 ── 3.4 W4 鼠标语义
  ├── 3.2 W2 导入范围
  ├── 3.3 W3 暂停语义 ── 3.5 W5 WebContent 恢复
  └── 4.1 U1 安装事务 ── 4.2 U2 健康确认 ── 4.3 U3 跨进程锁
                        └── 4.4 U4 发布入口 ── 4.5 U5 冒烟门禁
```

建议顺序：

1. **阶段 0**（测试缝 + TSan 修复）。
2. **D1 + D3 + D2 + P5**（数据安全闭环，先于任何播放/网页优化）。
3. **P1 + P2**（队列调度与 ffmpeg 状态机，用户可见故障最高频）。
4. **U1 最小补丁**（可立即做，不必等完整阶段 4）。
5. **W1 + W2**（外部副作用与导入范围，优先级高于网页体验完善）。
6. **P3 + P4 + W3 + W4 + W5**（正确性与恢复完善）。
7. **U2-U5**（完整安装事务与发布门禁）。
8. **阶段 5**（全量验收）。

---

## 6. 不建议现在做的事

1. **不要直接重写 WallpaperManager 或整体迁移架构**：本轮问题集中在状态协议和提交顺序，局部抽象即可；全量重写会扩大回归面。
2. **不要为追求覆盖率数字而补无行为价值的测试**：先覆盖已确认失败路径和 Worker/Manager 边界。
3. **不要合并 `feat/0.2.8-update-experience` 后再修**：另一个分支的每屏设置、稳定显示器档案与更新器改动会改变本报告的基线；应先在本分支冻结修复，再单独做整合评估。
4. **不要重新引入登录/OAuth 网页弹窗**：用户已明确放弃该兼容；W1 的修复只收紧外部导航，不恢复登录窗口。
5. **不要把“支持 HTTP”本身当漏洞**：应用明确支持 HTTP/HTTPS；需要修的是无用户手势的外部导航和导入范围，而不是协议本身。
6. **不要用 `open -W` 作为安装健康确认**：它会等到应用关闭，仍不能证明初始化成功。
7. **不要只用更长的固定超时掩盖问题**：watchdog、安装等待、网页恢复都需要状态与预算，而不是拍一个更大的数字。

---

## 7. 计划完成定义（Definition of Done）

一个阶段完成，必须同时满足：

- 该阶段所有 P1/P2 有对应回归测试，且测试在修复前稳定失败、修复后稳定通过；
- 没有引入新的 TSan 告警；
- 核心测试、Release 构建、模板校验、`git diff --check` 通过；
- 相关真实桌面脚本通过（单屏至少；双屏项单独标注）；
- 变更说明写清用户可见行为、兼容性和未覆盖限制；
- 没有未处理的静默 `try?` 用于新增的跨文件提交路径；
- 文档与实现一致，历史报告不被改写为当前事实。

---

## 8. 残余验证与未决问题

以下内容本轮**没有**完成，不能当作已验收：

1. **真实双屏/热插拔**：本机只有一台在线显示器；P4 的双屏行为、断屏 4 小时、重连恢复需真实硬件或可控 display 注入。
2. **真实远程网站**：本轮未访问外部站点；W1/W3/W5 的重定向、认证、Cookie、ATS 行为需实际网站验收。
3. **真实安装**：U1/U2/U3 只在临时目录和代码层验证；未替换真实 `/Applications` App，未测试断电/强制退出。
4. **多实例**：U3 未实际启动两个运行实例。
5. **CGEvent 鼠标**：W4 由代码路径确认，未发送真实鼠标事件。
6. **WebContent 主动终止**：W5 由 SDK 契约与代码路径确认，未实际 kill 渲染进程。
7. **签名/公证**：本轮未读取 secrets、未做 Developer ID 或公证验证。
8. **登录/OAuth**：按用户决定排除，未评估。
9. **严重度分歧项**：D4 与 W2 的两位复核者评级不一致，最终以“先修复、再按实际影响复评”处理。

这些残余项必须在阶段 5 或对应阶段验收时补齐，不能用现有自动化结果替代。

---

## 9. 结论

当前项目正常路径的构建、95 次核心测试执行、单屏桌面播放与内存回归均通过，基础工程质量不差。但本轮深查发现的风险集中在**跨层状态协议**，而不是单个函数的局部错误：

- 数据的多文件提交没有统一事务，失败时会丢失用户配置；
- 异步回调没有库/队列/会话代际，晚到结果可以污染新状态；
- 播放、暂停、热插拔和删除共享一套未收敛的调度协议；
- WebKit 把 `.linkActivated` 当作用户手势，导入范围与授权范围被隐式扩大；
- 更新安装把“复制/受理”当作“成功”，缺少事务与健康确认；
- 测试套件对上述 App 编排层的覆盖接近空白，部分脚本的“通过”名不副实。

因此建议先做阶段 0-1（测试底座 + 数据安全），再做阶段 2-4，最后用阶段 5 的真实硬件与发布门禁收口。这样每一步都有可复现的失败测试和明确的完成定义，符合“往深处做”而不是“把内容做广”的目标。

---

## 10. 实施进度（2026-11-07）

### 已完成

| 项 | 状态 | 验证 |
|---|---|---|
| 弱网测试桩 TSan 竞态 | 已修复 | TSan 修复前 20 轮中 10 轮告警；修复后 8 轮、最终 6 轮均 0 告警 |
| 重复测试登记与未使用变量 | 已清理 | 95 次执行 → 94 个独立测试；无相关编译警告 |
| D4 迁移完整性校验 | 已修复 | 新增 `testEmptyModernBindingsDoNotRetireNonEmptyLegacyQueues`；关闭校验时稳定失败，恢复后通过 |
| D5 网页相对入口持久化 | 已修复 | 新增 `testRelocationPreservesNestedEntryAfterRestart`、`testRelocationRejectsMissingOriginalEntry`；忽略相对入口时两项稳定失败，恢复后通过 |
| D1 加载失败保护 | 已实现 | 新增 `LibraryPersistenceGate` 与 `WallpaperStore.loadPlaybackQueueConfiguration()`；损坏文件阻止 Store/Manager 写入，缺失文件不误判；队列管理界面显示错误与重试入口；新增三项字节不变/修复解锁测试，关闭 Store 门禁时测试稳定失败 |
| D2 库会话隔离 | 已实现 | 切库时轮换 session、清空旧 UI 状态；所有异步 mutation 在 `await` 后校验 session；undo/toast/sheet 状态一并清理 |
| D3 删除事务（最小版） | 已实现 | 两个删除入口改为“主索引成功后再清理播放/队列”；删除当前项时按原 enabled 与成功应用的后继判断是否重启；加载时清理悬空队列 ID；新增 `PlaybackIndexReconciler` 及索引重锚定测试 |
| P1 统一队列调度 | 已实现 | 新增 `PlaybackSchedulingState` 与 `PlaybackDeadlineMath`；手动/系统暂停冻结调度，恢复保留剩余时间，回调带代际；真实菜单栏暂停/恢复及全屏 TextEdit 挂起/恢复脚本通过 |
| P2 ffmpeg 退出与排空状态机 | 已实现 | 退出回调只记录状态，读取队列 drain 后决定循环/完成；非零、零帧和不完整尾帧不重启；进程/心跳/入队/完成均按代际隔离；新增异常启动次数测试 |
| P3 AVPlayer 进度心跳与时长更新 | 已实现并复核 | 新增 `VideoPlaybackProgressTracker`；原生播放器只在 ready/playing 且 currentTime 前进时续期；时长变化只修正 stall watchdog/暂停快照，不重置硬截止；62 秒无元数据视频实测自然结束推进；独立复核无回归发现 |
| P4 显示器差异协调 | 已实现并复核 | 新增 `DisplayReconciler`；无关屏保持 player/session，几何变化只更新 frame；断屏清两类 timer/session 但保留 enabled 与手动暂停，重连只恢复目标屏并应用每屏播放意图；缺屏回调不持久化停用；独立复核无回归发现，真实双屏仍待验收 |
| W1 外部导航授权 | 已实现 | 新增 `ExternalNavigationAuthorizer` 与鼠标目标解析；真实 mouseUp 的单调时钟授权、URL 匹配、一次消费、状态失效；自动点击 0 次 opener、真实点击恰好 1 次；运行中关闭交互会取消授权 |
| U1 更新安装事务 | 已实现 | 同目录完整 sibling + plist/版本/可执行文件/签名校验 + `RENAME_SWAP` 原子替换与回滚；真实脚本覆盖复制失败、启动失败、成功、版本不符；打包 App `--update-swap` 冒烟通过 |
| W2 单文件导入范围 | 已实现 | 单 HTML 只复制/授权该文件；目录项目保留相对资源；Worker 预计算范围、文件数与估算大小并展示；新增无关/隐藏/嵌套哨兵测试 |
| W3 持续暂停 | 已实现并复核 | 使用公开 `setAllMediaPlaybackSuspended` 阻止已有/新增媒体再次播放；初始挂起在加载前应用；允许恢复重载时销毁并重建整页；实测反复 play 仍保持暂停；暂停会取消待恢复任务，恢复回调再次校验状态；旧健康任务不会重置预算，独立复核无回归发现 |
| W4 鼠标配对 | 已实现并复核 | mouseUp 先核对按下目标、6px 拖动/取消/修饰键，再由宿主授权并激活保存目标一次；fallback 保留 clientX/Y；真实 CGEvent 同目标一次、小幅拖动一次、跨目标零次；独立复核无回归发现 |
| W5 WebContent 恢复 | 已实现并复核 | 新增 `WebContentRecoveryState`，错误状态、10 秒加载超时、1/2/4 秒有上限退避、30 秒健康后重置；真实终止测试 renderer 后自动恢复；旧健康回调、销毁任务引用和暂停交错已收口，独立复核无回归发现 |
| U2 启动健康确认 | 已实现 | 新增 `UpdateHealthHandshake`；`open --args` 携带一次性 token，新 App 在关键初始化后原子回执；无确认/超时/错误 token 回滚；真实打包 App 回执通过 |
| U3 跨进程安装锁 | 已实现 | 新增 `UpdateInstallLock`，以目标路径 flock；同一锁描述符交给 detached helper，交换前校验真实 fd 身份与 owner；进程互斥/释放及 helper 交接测试通过 |
| U4 发布快照与清单 | 已实现 | `build-release.sh` 一次冻结 App，同源生成 ZIP/DMG，最终签名与 SUMS 复验；`build-dmg.sh` 不再重建；挂载 DMG 与 App 逐文件比较通过 |
| U5 线上冒烟门禁 | 已实现 | 生产模式强制远程 ZIP/SUMS/SIG 与嵌入公钥；显式诊断模式不输出 PASSED；本地 HTTP 正例、缺签名/错误哈希/404/错误公钥故障注入通过 |
| F1 四种适配方式 | 已实现并复核修正 | 新增 fill/fit/stretch/tile 与设置文案；嵌套 CAReplicatorLayer 用于图片/AVPlayer；ffmpeg 按源比例输出并共享一次解码/帧转图；几何变化重算网格、暂停重建保留当前帧、展示更新主线程串行、按屏幕缩放换算像素为点；真实图片/H.264/AV1 截图验证原生尺寸平铺 |

### 本轮验证结果

- `swift run WallpaperMacCoreTests`：**122/122 通过**（94 个原有独立测试 + 28 个新增回归测试）。
- `swift build -c release`：通过。
- 桌面 App 冒烟、图片/视频/网页播放器矩阵、AV1 兼容播放：通过。
- 真实菜单栏暂停/恢复与全屏 TextEdit 系统挂起/恢复：通过。
- 假 ffmpeg 异常退出：启动恢复阶段最多 2 次启动，随后不继续重启。
- 62 秒无元数据 H.264：第 55 秒仍播放，第 65 秒已自然完成并推进，无 60 秒误切。
- WebKit 自动 `target=_blank`：0 次外部打开；真实 CGEvent 点击：恰好 1 次 opener。
- 更新安装脚本故障注入、`RENAME_SWAP` 回滚和打包 App 原子交换冒烟：通过。
- 真实 App 健康 token 回执、跨进程锁互斥/释放、helper 锁继承：通过。
- 同源 ZIP/DMG/SIG/SUMS 生成与挂载比较：通过。
- 线上冒烟本地正例与缺签名/错误哈希/404/错误公钥故障注入：通过。
- 图片、H.264、AV1 的 32×16 四色图案平铺截图：均验证原生尺寸重复与比例保持。
- WebKit 媒体反复 play 的暂停/恢复、真实 WebContent 终止恢复：通过。
- 队列切换与长视频流内存回归：通过。
- TSan：最终 6 轮 0 告警。
- `git diff --check`：通过。

### 尚未开始或仍待补强

- D1 的“备份并重置损坏文件”恢复入口尚未实现；当前只支持修复文件后点“重新加载”。
- D2 的库会话检查目前依赖代码审查与静态枚举，尚无 App 层自动化测试；后续可抽取出 Core 可测试的会话协调器。
- D3 的对账逻辑尚未下沉为 Core 纯函数；`persistAssignments` 仍用 `try?`，持久化错误尚未统一上报；`remove(ids:)` 的幂等删除 API 尚未加入。
- U2 启动健康确认及 U3-U5 项目。
- W1/U1 最终独立审查代理未返回结构化结果，已停止；W2-W5 的修正项独立复核均无回归发现。
- U2-U5 的最终独立复核均无回归发现；真实 GitHub 上传后生产冒烟、真实 `/Applications` 替换、强制断电和双屏仍属于发布/硬件验收，不在本轮执行。
- W1/U1 最终独立审查代理未返回结构化结果，已停止；本批结论以 Core 行为测试、真实桌面、故障注入和打包助手冒烟为依据。
- 真实桌面双屏、真实网站、真实安装与 WebContent 终止验收。


