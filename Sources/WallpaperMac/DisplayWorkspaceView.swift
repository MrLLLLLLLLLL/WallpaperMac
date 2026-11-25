import SwiftUI
import WallpaperMacCore

struct DisplayWorkspaceView: View {
    @ObservedObject var model: LibraryViewModel
    let displayID: String
    @State private var isPickerPresented = false

    var body: some View {
        if let display = model.displayService.displays.first(where: { $0.id == displayID }) {
            workspace(display)
        } else {
            unavailable
        }
    }

    private func workspace(_ display: DisplayService.Display) -> some View {
        VStack(spacing: 0) {
            header(display)
            ThemeHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nowPlaying(display)
                    assignment(display)
                    quickAssign(display)
                    displayInfo(display)
                }
                .padding(20)
            }
        }
        .background(AppTheme.Palette.canvas)
        .sheet(isPresented: $isPickerPresented) {
            WallpaperPickerSheet(model: model, display: display)
        }
    }

    private func header(_ display: DisplayService.Display) -> some View {
        HStack(spacing: 10) {
            ThemeIconButton(systemName: "chevron.left", help: "返回显示器总览") {
                model.destination = .displaysOverview
            }
            Text(display.name)
                .font(AppTheme.Typography.pageTitle)
                .foregroundStyle(AppTheme.Palette.text)
                .lineLimit(1)
            modeBadge
            Spacer(minLength: 8)
            Text(resolutionText(display))
                .font(AppTheme.Typography.mono(9.5))
                .foregroundStyle(AppTheme.Palette.textTertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: MainWindowMetrics.libraryHeaderHeight)
    }

    private func nowPlaying(_ display: DisplayService.Display) -> some View {
        let snapshot = snapshot(for: display)
        return VStack(alignment: .leading, spacing: 10) {
            ThemeSectionHeader(title: "正在播放")
            HStack(alignment: .top, spacing: 18) {
                preview(snapshot.item)
                    .frame(width: 380)
                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot.sourceTitle)
                        .font(AppTheme.Typography.display(20))
                        .foregroundStyle(AppTheme.Palette.text)
                        .lineLimit(2)
                    Text(snapshot.sourceDetail)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    controls(display, snapshot: snapshot)
                    if let queue = snapshot.queue,
                       snapshot.isQueueActive,
                       let state = snapshot.state {
                        HStack(spacing: 12) {
                            Text("第 \(state.currentIndex + 1) / \(queue.wallpaperIDs.count) 项")
                                .font(AppTheme.Typography.mono(9))
                            Text("每 \(Int(queue.defaultIntervalSeconds)) 秒")
                                .font(AppTheme.Typography.mono(9))
                            Text(queue.transition.title)
                                .font(AppTheme.Typography.caption)
                        }
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .themeInsetSurface()
        }
    }

    private func preview(_ item: WallpaperItem?) -> some View {
        Group {
            if let item {
                WallpaperPreviewFrame {
                    ThumbnailView(item: item)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                        .stroke(AppTheme.Palette.hairline, lineWidth: 1)
                )
            } else {
                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                    .fill(AppTheme.Palette.raised)
                    .aspectRatio(CGFloat(WallpaperPreviewLayout.aspectRatio), contentMode: .fit)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "display")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(AppTheme.Palette.textTertiary)
                            Text("选择壁纸或队列")
                                .font(AppTheme.Typography.micro)
                                .foregroundStyle(AppTheme.Palette.textTertiary)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                            .stroke(AppTheme.Palette.hairline, lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private func controls(_ display: DisplayService.Display, snapshot: DisplaySnapshot) -> some View {
        HStack(spacing: 8) {
            if snapshot.item == nil {
                Button("选择壁纸") { isPickerPresented = true }
                    .buttonStyle(AccentActionButtonStyle(compact: true))
            } else {
                if snapshot.isQueueActive,
                   let queue = snapshot.queue,
                   queue.wallpaperIDs.count > 1 {
                    ThemeIconButton(systemName: "forward.end", help: "下一项") {
                        model.wallpaperManager.skipToNextQueueItem(displayID: display.id)
                    }
                }
                if isStatic(snapshot) {
                    Text("静态")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .frame(width: 24, height: 24)
                } else {
                    ThemeIconButton(
                        systemName: snapshot.playback?.isPlaying == true ? "pause.fill" : "play.fill",
                        help: snapshot.playback?.isPlaying == true ? "暂停" : "播放"
                    ) {
                        model.wallpaperManager.togglePlayback(for: display.id)
                    }
                }
                if !isStatic(snapshot) {
                    ThemeIconButton(
                        systemName: snapshot.playback?.isMuted == true ? "speaker.slash" : "speaker.wave.2",
                        help: snapshot.playback?.isMuted == true ? "取消静音" : "静音"
                    ) {
                        model.wallpaperManager.setMuted(!(snapshot.playback?.isMuted ?? true), for: display.id)
                    }
                }
                Button("更换壁纸") { isPickerPresented = true }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
    }

    private func assignment(_ display: DisplayService.Display) -> some View {
        let snapshot = snapshot(for: display)
        return VStack(alignment: .leading, spacing: 10) {
            ThemeSectionHeader(title: "分配")
            HStack(alignment: .top, spacing: 12) {
                fixedWallpaperCard(display, snapshot: snapshot)
                queueCard(display, snapshot: snapshot)
            }
            VStack(alignment: .leading, spacing: 10) {
                slotRow(display, kind: .normal)
                ThemeHairline()
                slotRow(display, kind: .hidden)
            }
            .padding(12)
            .themeInsetSurface()
            Text("队列槽位决定当前隐藏模式使用哪条队列；固定壁纸会停止当前队列。")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
        }
    }

    private func fixedWallpaperCard(_ display: DisplayService.Display, snapshot: DisplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("固定壁纸")
                .font(AppTheme.Typography.section)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text(snapshot.isQueueActive ? "当前由队列播放" : (snapshot.item?.name ?? "未分配"))
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(snapshot.item == nil ? AppTheme.Palette.textTertiary : AppTheme.Palette.text)
                .lineLimit(1)
            Text(snapshot.isQueueActive ? "选择壁纸会停止队列并切换为固定壁纸" : "不在队列中时显示这张壁纸")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button("选择壁纸") { isPickerPresented = true }
                    .buttonStyle(AccentActionButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .themeInsetSurface()
    }

    private func queueCard(_ display: DisplayService.Display, snapshot: DisplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前队列")
                .font(AppTheme.Typography.section)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text(snapshot.queue?.name ?? "未绑定队列")
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(snapshot.queue == nil ? AppTheme.Palette.textTertiary : AppTheme.Palette.text)
                .lineLimit(1)
            Text(queueDetail(snapshot))
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let queue = snapshot.queue {
                    Button("编辑队列") {
                        model.destination = .queue(queue.id)
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    if !snapshot.isQueueActive && !queue.wallpaperIDs.isEmpty {
                        Button("播放队列") {
                            model.setActiveQueue(queue, for: display.id)
                        }
                        .buttonStyle(AccentActionButtonStyle(compact: true))
                    }
                } else {
                    Text("在下方槽位选择队列")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .themeInsetSurface()
    }

    private func queueDetail(_ snapshot: DisplaySnapshot) -> String {
        guard let queue = snapshot.queue else { return "当前模式没有可用队列" }
        let status = snapshot.isQueueActive ? "播放中" : "已停止"
        return "\(status)  \(queue.wallpaperIDs.count) 项  每 \(Int(queue.defaultIntervalSeconds)) 秒"
    }

    private func slotRow(_ display: DisplayService.Display, kind: PlaybackQueueKind) -> some View {
        let currentID = model.queueSlotID(for: display.id, kind: kind)
        let currentQueue = currentID.flatMap { model.wallpaperManager.queue(with: $0) }
        let isCurrentMode = (kind == .hidden) == model.showsHiddenWallpapers
        let options = model.queues(for: kind)
        return HStack(spacing: 10) {
            Text(kind == .normal ? "默认模式" : "隐藏模式")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: 64, alignment: .leading)
            Menu {
                ForEach(options) { queue in
                    Button(queue.name) {
                        _ = model.setQueueSlot(kind, queue: queue, for: display.id)
                    }
                }
                if kind == .hidden {
                    Divider()
                    Button("无") {
                        _ = model.setQueueSlot(.hidden, queue: nil, for: display.id)
                    }
                }
            } label: {
                ThemeMenuLabel(
                    title: currentQueue?.name ?? "未指定",
                    systemImage: kind == .hidden ? "eye.slash" : "list.bullet.rectangle"
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 8)
            if isCurrentMode {
                Text("当前")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AppTheme.Palette.accentWash))
            }
        }
    }

    private func quickAssign(_ display: DisplayService.Display) -> some View {
        let items = recommendedItems
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ThemeSectionHeader(title: "快速分配")
                        Spacer()
                        Button("选择更多") { isPickerPresented = true }
                            .buttonStyle(QuietButtonStyle(compact: true))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(items) { item in
                                Button {
                                    model.apply(item: item, to: display)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ThumbnailView(item: item)
                                            .frame(width: 120, height: 68)
                                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .stroke(AppTheme.Palette.hairline, lineWidth: 1)
                                            )
                                        Text(item.name)
                                            .font(AppTheme.Typography.micro)
                                            .foregroundStyle(AppTheme.Palette.textSecondary)
                                            .lineLimit(1)
                                            .frame(width: 120, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("应用 \(item.name)（会停止当前队列）")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text("点击缩略图会切换为固定壁纸并停止当前队列。")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
            }
        }
    }

    private var recommendedItems: [WallpaperItem] {
        model.wallpapers
            .filter { model.isWallpaperVisible($0) && $0.availability == .available }
            .sorted { first, second in
                if first.isFavorite != second.isFavorite { return first.isFavorite }
                let firstDate = first.lastUsedAt ?? first.createdAt
                let secondDate = second.lastUsedAt ?? second.createdAt
                return firstDate > secondDate
            }
            .prefix(10)
            .map { $0 }
    }

    private func displayInfo(_ display: DisplayService.Display) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeSectionHeader(title: "显示器")
            VStack(spacing: 0) {
                infoRow("分辨率", resolutionText(display))
                ThemeHairline()
                infoRow("硬件名称", display.identity.localizedName)
                ThemeHairline()
                infoRow("连接状态", "已连接")
                ThemeHairline()
                infoRow("当前模式", model.showsHiddenWallpapers ? "隐藏模式" : "默认模式")
                ThemeHairline()
                infoRow("默认槽位", slotName(display, kind: .normal))
                ThemeHairline()
                infoRow("隐藏槽位", slotName(display, kind: .hidden))
            }
            .themeInsetSurface()
        }
    }

    private func slotName(_ display: DisplayService.Display, kind: PlaybackQueueKind) -> String {
        guard let id = model.queueSlotID(for: display.id, kind: kind),
              let queue = model.wallpaperManager.queue(with: id) else {
            return kind == .hidden ? "无" : "未指定"
        }
        return queue.name
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(AppTheme.Typography.mono(9.5))
                .foregroundStyle(AppTheme.Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AppTheme.Palette.warning)
            Text("显示器当前不可用")
                .font(AppTheme.Typography.display(18))
                .foregroundStyle(AppTheme.Palette.text)
            Button("返回显示器总览") { model.destination = .displaysOverview }
                .buttonStyle(AccentActionButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(AppTheme.Palette.canvas)
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

    private func snapshot(for display: DisplayService.Display) -> DisplaySnapshot {
        DisplaySnapshot(model: model, display: display)
    }

    private func isStatic(_ snapshot: DisplaySnapshot) -> Bool {
        if singleStatic(snapshot.playback) { return true }
        return snapshot.item?.type == .image
    }

    private func singleStatic(_ playback: WallpaperManager.PlaybackState?) -> Bool {
        guard let playback else { return false }
        if case .staticImage = playback { return true }
        return false
    }

    private func resolutionText(_ display: DisplayService.Display) -> String {
        let geometry = display.identity.geometry
        guard geometry.pixelWidth > 0, geometry.pixelHeight > 0 else { return "分辨率未知" }
        return "\(geometry.pixelWidth) × \(geometry.pixelHeight)"
    }
}

struct WallpaperPickerSheet: View {
    @ObservedObject var model: LibraryViewModel
    let display: DisplayService.Display
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var items: [WallpaperItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.wallpapers
            .filter { model.isWallpaperVisible($0) && $0.availability == .available }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("选择壁纸")
                    .font(AppTheme.Typography.display(20))
                    .foregroundStyle(AppTheme.Palette.text)
                Text("应用到 \(display.name)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
            .padding(20)

            ThemeHairline()

            HStack(spacing: 12) {
                ThemeSearchField(placeholder: "搜索壁纸", text: $search, width: 260)
                Spacer()
                Text("\(items.count) 项")
                    .font(AppTheme.Typography.mono(9.5))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            .padding(16)

            if items.isEmpty {
                Text("没有可用的壁纸")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(items) { item in
                            Button {
                                model.apply(item: item, to: display)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ThumbnailView(item: item)
                                        .frame(height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                                                .stroke(AppTheme.Palette.hairline, lineWidth: 1)
                                        )
                                    Text(item.name)
                                        .font(AppTheme.Typography.micro)
                                        .foregroundStyle(AppTheme.Palette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("应用 \(item.name)")
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 760, height: 560)
        .background(AppTheme.Palette.canvas)
        .tint(AppTheme.Palette.accent)
    }
}
