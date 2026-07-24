# WallpaperMac 设置页版本信息设计

## 目标
在设置窗口中增加“关于 WallpaperMac”区域，让用户可以直接确认当前安装版本。

## 设计
- 设置页底部新增“关于 WallpaperMac”分组。
- 显示应用名称、版本号与构建号。
- 版本号读取 `Bundle.main` 的 `CFBundleShortVersionString`。
- 构建号读取 `Bundle.main` 的 `CFBundleVersion`。
- SwiftPM 开发运行缺少包元数据时，版本号回退为当前版本 `0.2.4`，构建号缺失时不重复显示。
- 使用原生 macOS 设置页样式和次要文字颜色，不增加交互按钮。

## 验收
- 打包后的 0.2.4 App 设置页显示“版本 0.2.4”。
- 当构建号与版本号相同时只显示一次版本号。
- 版本信息由 Bundle 元数据驱动，后续打包版本会自动同步。
