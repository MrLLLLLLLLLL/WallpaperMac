# WallpaperMac 实现接口约定

本文档只定义 UI 与核心服务之间的边界，不规定具体存储引擎、播放器库或持久化格式。

## 1. 核心枚举

```swift
enum WallpaperType: String, Codable, Sendable {
    case image
    case video
    case web
}

enum StorageMode: String, Codable, Sendable {
    case managedCopy
    case externalReference
}

enum WallpaperAvailability: String, Codable, Sendable {
    case available
    case importing
    case missing
    case unsupported
    case permissionDenied
}
```

## 2. 壁纸模型

```swift
struct WallpaperItem: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var type: WallpaperType
    var sourceURL: URL
    var entryURL: URL?
    var storageMode: StorageMode
    var thumbnailURL: URL?
    var availability: WallpaperAvailability
    var createdAt: Date
    var lastUsedAt: Date?
    var isFavorite: Bool
}
```

约定：

- `sourceURL` 表示应用管理的资源根路径或外部文件路径。
- `entryURL` 仅用于网页入口或需要明确主文件的资源。
- UI 不直接判断文件是否存在；由壁纸库服务提供 `availability`。
- 不将播放器实例、窗口引用或系统显示器对象放入可持久化模型。

## 3. 显示器分配

```swift
struct DisplayAssignment: Identifiable, Codable, Sendable {
    let id: String
    var displayName: String
    var isConnected: Bool
    var wallpaperID: UUID?
    var applicationState: ApplicationState
}

enum ApplicationState: String, Codable, Sendable {
    case idle
    case applying
    case applied
    case failed
    case disconnected
}
```

显示器识别应使用稳定的系统标识，不以显示器名称作为唯一键。显示器断开时保留 `wallpaperID`，但 `applicationState` 必须为 `disconnected`。

## 4. 播放策略

```swift
struct PlaybackPolicy: Codable, Sendable {
    var isPlaying: Bool
    var isMuted: Bool
    var loops: Bool
    var pauseOnBattery: Bool
    var pauseInFullScreenApps: Bool
    var reloadWebContentOnResume: Bool
}
```

默认值：

- `isMuted = true`。
- `loops = true`。
- 电池和全屏策略由用户设置决定。
- 网页恢复时是否重新加载由 `reloadWebContentOnResume` 控制。

## 5. 服务边界

### `WallpaperLibraryService`

职责：

- 导入图片、视频和本地 HTML 项目。
- 扫描目录并生成资源索引。
- 执行复制到应用库或保存外部引用。
- 生成缩略图和网页预览。
- 检查资源失效、权限和不支持格式。
- 重新定位和移除壁纸。

UI 只订阅状态和调用意图，不直接执行文件复制或目录扫描。

### `DisplayService`

职责：

- 获取系统显示器列表。
- 监听显示器连接/断开。
- 保存每块显示器的壁纸分配。
- 将应用、恢复和失败状态反馈给 UI。

### `WallpaperPlayerService`

职责：

- 为视频和网页创建播放承载。
- 应用/移除桌面壁纸窗口。
- 执行播放策略、静音、循环和暂停恢复。
- 处理屏幕休眠、唤醒、电池和全屏策略。
- 将播放器错误转换为可展示的状态。

### `PreferencesService`

职责：

- 保存壁纸库路径和存储模式。
- 保存播放、显示器和后台行为偏好。
- 提供设置界面的可观察状态。

## 6. SwiftUI 与 AppKit 分工

SwiftUI：

- 主窗口布局。
- 侧边栏、网格、列表、检查器。
- 导入 sheet、设置窗口和状态视图。
- 可观察模型和用户意图绑定。

AppKit：

- 桌面级壁纸窗口层级。
- 多显示器窗口管理。
- 登录时启动、系统显示器事件和全屏应用检测。
- 必要时承载 `WKWebView`、视频播放器或系统媒体组件。

## 7. 错误转换

底层错误必须转换为 UI 可理解的领域错误，例如：

- `libraryReadPermissionDenied`
- `libraryWritePermissionDenied`
- `unsupportedMediaType`
- `webEntryPointNotFound`
- `externalResourceMissing`
- `displayDisconnected`
- `playerFailedToStart`

每个错误应包含用户可读标题、影响说明、恢复操作和是否允许重试。
