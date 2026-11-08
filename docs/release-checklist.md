# 发布检查清单

适用于每次正式发布。版本号由仓库根目录的 `VERSION` 驱动，发布产物必须与该版本一致。

## 1. 发布前

- [ ] `VERSION` 已更新为 `x.y.z`
- [ ] `CHANGELOG.md` 有对应的 `## [x.y.z] - 日期` 段落
- [ ] `docs/release-notes/x.y.z.md` 已编写
- [ ] `UpdateService` 与 `SettingsWindowController` 的 `fallbackVersion` 已同步
- [ ] 工作区无意外未提交改动（报告类文件除外）

## 2. 测试

```bash
swift run WallpaperMacCoreTests
WALLPAPERMAC_UPDATE_SIGNING_KEY="$PWD/secrets/WallpaperMac.update.key" ./scripts/test-release.sh
```

- [ ] 单元测试全部通过
- [ ] `ALL_RELEASE_TESTS_PASSED`
- [ ] 无新增 WallpaperMac 崩溃报告

## 3. 构建

```bash
./scripts/build-dmg.sh
WALLPAPERMAC_UPDATE_SIGNING_KEY="$PWD/secrets/WallpaperMac.update.key" ./scripts/build-release.sh
```

- [ ] `dist/WallpaperMac-vx.y.z-macOS.dmg`
- [ ] `dist/WallpaperMac-vx.y.z-macOS.zip`
- [ ] `dist/WallpaperMac-vx.y.z-macOS.zip.sig`
- [ ] `dist/WallpaperMac-vx.y.z-SHA256SUMS.txt`
- [ ] 缺少签名密钥时构建失败（fail-closed），本地开发才使用 `WALLPAPERMAC_ALLOW_UNSIGNED=1`

## 4. 产物校验

```bash
shasum -a 256 dist/WallpaperMac-vx.y.z-macOS.zip dist/WallpaperMac-vx.y.z-macOS.dmg
cat dist/WallpaperMac-vx.y.z-SHA256SUMS.txt
swift scripts/update-signing-tool.swift verify \
  dist/WallpaperMac-vx.y.z-macOS.zip \
  dist/WallpaperMac-vx.y.z-macOS.zip.sig \
  secrets/WallpaperMac.update.key.pub
```

- [ ] 哈希与 `SHA256SUMS` 一致
- [ ] 签名校验输出 `SIGNATURE_OK`
- [ ] DMG 可挂载，应用版本正确，`codesign --verify --deep --strict` 通过
- [ ] `./scripts/smoke-app.sh` 输出 `APP_SMOKE_PASSED`

## 5. 发布

```bash
git tag -a vx.y.z -m "WallpaperMac x.y.z"
git push origin vx.y.z
gh release create vx.y.z \
  --title "WallpaperMac x.y.z" \
  --notes-file docs/release-notes/x.y.z.md \
  dist/WallpaperMac-vx.y.z-macOS.dmg \
  dist/WallpaperMac-vx.y.z-macOS.zip \
  dist/WallpaperMac-vx.y.z-macOS.zip.sig \
  dist/WallpaperMac-vx.y.z-SHA256SUMS.txt
```

- [ ] 标签指向发布提交
- [ ] Release 的四个资源齐全，且非草稿、非预发布
- [ ] GitHub `latest` 指向新版本

网络不稳时，推送可加 `-c http.version=HTTP/1.1` 并重试；`gh release create` 失败后可检查是否已创建，再用 `gh release upload` 补齐资源。

## 6. 发布后验证

```bash
./scripts/update-artifact-smoke.sh
```

- [ ] GitHub API 能解析出 zip、`SHA256SUMS`、`.sig` 三个地址
- [ ] 线上 `SHA256SUMS` 与本地产物哈希一致
- [ ] 线上 `.sig` 与本地签名逐字节一致，并能用发布公钥校验
- [ ] 用上一版本客户端实测能发现新版本

## 7. 真机升级验收

- [ ] 备份 `/Applications/WallpaperMac.app`、`~/Library/Application Support/WallpaperMac` 与 `com.wallpaper.mac` 偏好
- [ ] 安装上一版本，在设置中检查更新
- [ ] 下载完成后确认应用退出、替换、自动重启
- [ ] 升级后版本正确，壁纸库、队列、显示器分配与偏好保留
- [ ] 升级后再次检查更新显示「当前已是最新版本」
- [ ] 失败时确认 `/Applications/WallpaperMac.app.previous` 可用于回滚

## 8. 收尾

- [ ] 归档或删除已合并的发布分支
- [ ] 清理 `/tmp` 下的验收备份
- [ ] 确认 `main` 与发布标签指向同一提交

## 备注

- App 使用 ad-hoc 签名；首次启动若被 Gatekeeper 阻止，需在 Finder 中按住 Control 单击应用并选择「打开」。
- `secrets/` 永不提交；公钥内置于 `Sources/WallpaperMacCore/Update/UpdateSignature.swift`。
