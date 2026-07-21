# WallpaperMac 持久化与菜单栏修复设计

## 目标
修复 WallpaperMac 在重启后壁纸库/复制资源不可恢复的问题，并增加常驻菜单栏图标与基本控制菜单。

## 持久化设计

`WallpaperStore` 继续以用户选择的目录作为壁纸库根目录，使用 `wallpapers.json` 保存壁纸记录、`display-assignments.json` 保存显示器分配、`Assets/` 保存 managed copy 资源。应用配置目录新增 `library-bookmark.data`，用于记录用户授权的壁纸库目录书签。

启动时由 `LibraryViewModel` 创建 `WallpaperLibraryAccess`，恢复已保存路径和书签，解析出可读写的目录后创建 `WallpaperStore`。如果书签或路径不可用，保留记录与配置，发布可理解的库访问状态，不自动切换到空的默认目录或删除元数据。

用户通过选择文件夹改变库位置时，先创建目录并保存书签，再切换 Store；如果访问或保存失败，继续使用旧 Store，不丢失旧库。

## 启动恢复设计

AppDelegate 持有主窗口和状态栏协调器。主窗口的 `LibraryViewModel` 在加载完成后读取壁纸记录；WallpaperManager 根据已保存的 display assignments 和当前显示器集合恢复可用壁纸。缺失资源保留为 missing 状态，等待用户重新定位。

## 菜单栏设计

新增 `StatusBarController`，由 AppDelegate 强引用。它创建 template `NSStatusItem`，菜单提供：

- 打开主窗口
- 暂停/继续动态壁纸
- 静音/取消静音
- 打开壁纸库
- 打开设置
- 退出应用

菜单栏层只调用一个注入的 `StatusBarActions`/闭包接口，不直接操作播放器窗口；主窗口关闭后状态栏仍然存在。

## 测试边界

核心测试验证 Store 重新实例化后仍能读取 managed copy 和自定义库路径；应用测试验证状态栏控制器生成图标与菜单项。系统级菜单栏显示由 Release smoke/build 验证，不能在无 AppKit 运行环境的 Core 测试中完全模拟。
