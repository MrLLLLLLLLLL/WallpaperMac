# 网页壁纸模板导入

仓库内置一个无需网络的最小网页壁纸项目，位于：

```text
Templates/SimpleWebWallpaper/
```

它用于验证 WallpaperMac 的本地 HTML 导入、入口文件选择、`WKWebView` 承载、暂停/恢复、静音与重新加载等基础路径。模板不是在线壁纸市场，也不依赖 CDN、远程图片或第三方脚本。

## 模板文件

```text
SimpleWebWallpaper/
├── index.html   # HTML 入口
├── styles.css   # 深色渐变与轻量动画
├── script.js    # 本地时钟更新
└── README.md    # 模板说明
```

`index.html` 通过 `./styles.css` 与 `./script.js` 引用同目录文件。保留相对路径能确保“复制到应用库”和“引用原文件”两种导入方式都能找到资源。

## 导入步骤

1. 启动 WallpaperMac。
2. 将 `Templates/SimpleWebWallpaper` 整个目录拖入主窗口，或在“导入壁纸”中选择这个目录。
3. 当应用要求选择入口文件时，选择 `index.html`。
4. 先选择“引用原文件”完成一次导入与预览，再删除导入记录；随后选择“复制到应用库”重复验证。
5. 在右侧检查器中应用到一个显示器，确认时间每秒变化且背景存在轻量动画。
6. 分别测试暂停、继续、静音、重新加载和从菜单栏控制动态壁纸。

## 创建自己的网页壁纸

建议以模板为起点复制一个目录，再替换内容：

- 保持所有 HTML、CSS、JavaScript、图片、字体和媒体文件放在项目目录内。
- 优先使用相对路径，例如 `./assets/background.png`，不要使用依赖本机绝对路径的资源。
- 避免在线 URL、CDN 或外部脚本；离线运行和网络隔离是本地网页壁纸的基本预期。
- 不要在网页中要求用户输入隐私信息，也不要把 Cookie、Token 或本机文件写入页面。
- 为视频/音频设置静音或不自动播放音频；WallpaperMac 对视频和网页默认静音。
- 在性能敏感场景中减少高频 DOM 更新、无限创建定时器和过大的 Canvas/WebGL 纹理；这类行为会影响桌面功耗与内存占用。

## 自动校验

仓库提供以下脚本以确保模板保持离线、可导入：

```bash
./scripts/validate-web-wallpaper-template.sh
```

它会验证必需文件、相对路径、时钟元素与定时逻辑，并拒绝 HTML/CSS/JavaScript 中的外部网络依赖。
