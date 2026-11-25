import SwiftUI
import WallpaperMacCore

struct DisplaysOverviewView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("显示器")
                    .font(AppTheme.Typography.pageTitle)
                    .foregroundStyle(AppTheme.Palette.text)
                Spacer()
                Text("\(displays.count) 台已连接")
                    .font(AppTheme.Typography.mono(9.5))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 20)
            .frame(height: MainWindowMetrics.libraryHeaderHeight)

            ThemeHairline()

            if displays.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(displays) { display in
                            DisplayStatusCard(
                                model: model,
                                display: display,
                                snapshot: snapshot(for: display)
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(AppTheme.Palette.canvas)
    }

    private var displays: [DisplayService.Display] {
        model.displayService.displays
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 150, height: 84)
                Image(systemName: "display")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            Text("没有已连接的显示器")
                .font(AppTheme.Typography.display(18))
                .foregroundStyle(AppTheme.Palette.text)
            Text("连接显示器后，每块屏幕会出现在这里。")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func snapshot(for display: DisplayService.Display) -> DisplaySnapshot {
        DisplaySnapshot(model: model, display: display)
    }
}

struct DisplaySnapshot {
    let item: WallpaperItem?
    let queue: PlaybackQueue?
    let state: DisplayQueueState?
    let playback: WallpaperManager.PlaybackState?

    /// Shared assembly used by both the overview grid and the single-display
    /// workspace so the two never drift apart.
    @MainActor
    init(model: LibraryViewModel, display: DisplayService.Display) {
        let itemID = model.wallpaperManager.appliedWallpaperIDs[display.id]
        item = itemID.flatMap { id in model.wallpapers.first(where: { $0.id == id }) }
        let queue = model.wallpaperManager.effectiveQueue(for: display.id)
        self.queue = queue
        state = queue.flatMap { model.wallpaperManager.state(for: display.id, queueID: $0.id) }
        playback = model.wallpaperManager.playbackStates[display.id]
    }

    var isQueueActive: Bool {
        queue != nil && state?.isEnabled == true
    }

    var sourceTitle: String {
        if isQueueActive, let queue { return queue.name }
        return item?.name ?? "未分配"
    }

    var sourceDetail: String {
        if isQueueActive, let queue, let state {
            return "队列 \(state.currentIndex + 1)/\(queue.wallpaperIDs.count)"
        }
        if item != nil { return "固定壁纸" }
        return "尚未分配壁纸或队列"
    }
}

private struct DisplayStatusCard: View {
    @ObservedObject var model: LibraryViewModel
    let display: DisplayService.Display
    let snapshot: DisplaySnapshot

    private var isPlaying: Bool {
        snapshot.playback?.isPlaying == true
    }

    private var isMuted: Bool {
        snapshot.playback?.isMuted ?? model.playbackPolicy.isMuted
    }

    private var isStatic: Bool {
        if case .staticImage = snapshot.playback { return true }
        return snapshot.item?.type == .image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.destination = .display(display.id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(display.name)
                            .font(AppTheme.Typography.bodyMedium)
                            .foregroundStyle(AppTheme.Palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        modeBadge
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                    }
                    Text(resolutionText)
                        .font(AppTheme.Typography.mono(9))
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                    preview
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.sourceTitle)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .lineLimit(1)
                    Text(snapshot.sourceDetail)
                        .font(AppTheme.Typography.mono(8.5))
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                controls
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.panelCorner, style: .continuous)
                .fill(AppTheme.Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.panelCorner, style: .continuous)
                .stroke(AppTheme.Palette.hairline, lineWidth: 1)
        )
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                .fill(AppTheme.Palette.raised)
            if let item = snapshot.item {
                ThumbnailView(item: item)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(AppTheme.Palette.accent)
                    Text("未分配")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
            }
            if let item = snapshot.item, snapshot.isQueueActive {
                VStack {
                    Spacer()
                    HStack {
                        Text(item.name)
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.5), in: Capsule())
                        Spacer()
                    }
                }
                .padding(8)
            }
        }
        .aspectRatio(CGFloat(WallpaperPreviewLayout.aspectRatio), contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                .stroke(AppTheme.Palette.hairline, lineWidth: 1)
        )
        .clipped()
    }

    private var modeBadge: some View {
        Text(model.showsHiddenWallpapers ? "隐藏模式" : "默认模式")
            .font(AppTheme.Typography.micro)
            .foregroundStyle(
                model.showsHiddenWallpapers
                    ? AppTheme.Palette.accent
                    : AppTheme.Palette.textTertiary
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    model.showsHiddenWallpapers
                        ? AppTheme.Palette.accentWash
                        : AppTheme.Palette.raised
                )
            )
    }

    @ViewBuilder
    private var controls: some View {
        if snapshot.item == nil {
            Button("分配") {
                model.destination = .display(display.id)
            }
            .buttonStyle(AccentActionButtonStyle(compact: true))
        } else {
            if snapshot.isQueueActive, let queue = snapshot.queue, queue.wallpaperIDs.count > 1 {
                ThemeIconButton(systemName: "forward.end", help: "下一项") {
                    model.wallpaperManager.skipToNextQueueItem(displayID: display.id)
                }
            }
            if isStatic {
                Text("静态")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .frame(width: 24, height: 24)
            } else {
                ThemeIconButton(
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    help: isPlaying ? "暂停" : "播放"
                ) {
                    model.wallpaperManager.togglePlayback(for: display.id)
                }
            }
            if !isStatic {
                ThemeIconButton(
                    systemName: isMuted ? "speaker.slash" : "speaker.wave.2",
                    help: isMuted ? "取消静音" : "静音"
                ) {
                    model.wallpaperManager.setMuted(!isMuted, for: display.id)
                }
            }
        }
    }

    private var resolutionText: String {
        let geometry = display.identity.geometry
        guard geometry.pixelWidth > 0, geometry.pixelHeight > 0 else { return "分辨率未知" }
        return "\(geometry.pixelWidth) × \(geometry.pixelHeight)"
    }
}
