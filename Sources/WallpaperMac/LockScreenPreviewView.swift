import SwiftUI
import AppKit
import WallpaperMacCore

/// Inspector section for the selected wallpaper's lock-screen image. The
/// preview follows the same static resource selection as synchronization:
/// override first, live web snapshot when ready, then image/thumbnail fallback.
struct LockScreenPreviewView: View {
    @ObservedObject var model: LibraryViewModel
    let item: WallpaperItem
    @State private var image: NSImage?

    private var taskID: String {
        [
            item.id.uuidString,
            String(model.lockScreenPreviewVersion),
            item.lockScreenOverrideURL?.path ?? "",
            item.thumbnailURL?.path ?? "",
            item.sourceURL.path,
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeSectionHeader(title: "锁屏预览")
            WallpaperPreviewFrame {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .background(Color.black)
                } else {
                    ZStack {
                        Color.black
                        Text(item.type == .web ? "页面加载完成后显示锁屏预览" : "暂无可用锁屏图片")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(12)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button("替换锁屏图片…") { model.replaceLockScreenImage(for: item) }
                    .buttonStyle(AccentActionButtonStyle(compact: true))
                if item.lockScreenOverrideURL != nil {
                    Button("恢复自动预览") { model.clearLockScreenOverride(for: item) }
                        .buttonStyle(QuietButtonStyle(compact: true))
                }
            }
            Text(item.lockScreenOverrideURL == nil ? "由应用根据当前壁纸生成" : "使用自定义锁屏图片")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: taskID) {
            image = await model.lockScreenPreviewImage(for: item)
        }
    }
}
