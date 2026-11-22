import SwiftUI
import WallpaperMacCore

struct QueueManagementView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var selectedQueueID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var queueToDelete: PlaybackQueue?

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.wallpaperManager.queueLoadError {
                queueLoadWarning(error)
            } else if let error = model.wallpaperManager.queueSaveError {
                queueSaveWarning(error)
            }
            HStack(spacing: 0) {
                queueList
                    .frame(width: 230)
                ThemeVerticalHairline()
                if let queue = selectedQueue {
                    queueDetail(queue)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                        Text("还没有播放队列")
                            .font(AppTheme.Typography.display(18))
                            .foregroundStyle(AppTheme.Palette.text)
                        Text("创建一个队列后，可以将图片、视频和网页壁纸加入其中。")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(model.wallpaperManager.isQueuePersistenceBlocked)
        }
        .background(AppTheme.Palette.canvas)
        .onAppear {
            if selectedQueueID == nil {
                selectedQueueID = model.queueLibrary.first?.id
            }
        }
        .onChange(of: model.queueLibrary) { queues in
            if let selectedQueueID, queues.contains(where: { $0.id == selectedQueueID }) { return }
            self.selectedQueueID = queues.first?.id
        }
        .sheet(isPresented: $model.isNewQueueSheetPresented) {
            NewQueueSheet { name in
                if let created = model.createQueue(named: name) {
                    selectedQueueID = created.id
                }
            }
        }
        .confirmationDialog("删除播放队列？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let queueToDelete { model.deleteQueue(queueToDelete) }
                queueToDelete = nil
            }
            Button("取消", role: .cancel) { queueToDelete = nil }
        } message: {
            Text("队列中的壁纸记录不会被删除；正在使用该队列的显示器会切换到默认队列。")
        }
    }

    private func queueLoadWarning(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Palette.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("播放队列文件无法加载")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("为避免覆盖原文件，队列修改暂不保存。修复或恢复文件后可重新加载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新加载") {
                if !model.wallpaperManager.retryLoadingQueues() {
                    model.lastError = model.wallpaperManager.queueLoadError
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func queueSaveWarning(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Palette.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("播放队列保存失败")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("最近的队列修改可能没有写入磁盘，请检查磁盘空间或权限后重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var selectedQueue: PlaybackQueue? {
        guard let selectedQueueID else { return nil }
        return model.queueLibrary.first(where: { $0.id == selectedQueueID })
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("队列库")
                    .font(AppTheme.Typography.display(18))
                    .foregroundStyle(AppTheme.Palette.text)
                Spacer(minLength: 8)
                ThemeIconButton(systemName: "plus", help: "新建播放队列") {
                    model.beginCreateQueue()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: MainWindowMetrics.libraryHeaderHeight)

            ThemeHairline()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.queueLibrary) { queue in
                        queueRow(queue)
                    }
                }
                .padding(8)
            }
        }
        .background(AppTheme.Palette.sidebar)
    }

    private func queueRow(_ queue: PlaybackQueue) -> some View {
        let isSelected = selectedQueueID == queue.id
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isSelected ? AppTheme.Palette.brass : Color.clear)
                .frame(width: 2, height: 15)
            Image(systemName: queue.isDefault ? "star.fill" : "list.bullet.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? AppTheme.Palette.brass : AppTheme.Palette.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(queue.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppTheme.Palette.text : AppTheme.Palette.textSecondary)
                    .lineLimit(1)
                Text("\(visibleWallpaperCount(queue)) 项  \(model.queueKind(queue).title)")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? AppTheme.Palette.brassWash : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedQueueID = queue.id }
        .contextMenu {
            Button("复制队列") { model.duplicateQueue(queue) }
            if !queue.isDefault {
                Button("删除队列", role: .destructive) {
                    queueToDelete = queue
                    showingDeleteConfirmation = true
                }
            }
        }
    }

    private func queueDetail(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(queue.name)
                        .font(AppTheme.Typography.display(20))
                        .foregroundStyle(AppTheme.Palette.text)
                    Text(queue.isDefault ? "系统默认队列，不可删除" : "命名播放队列")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                Spacer()
                Button("复制") { model.duplicateQueue(queue) }
                    .buttonStyle(QuietButtonStyle())
                if !queue.isDefault {
                    Button("删除", role: .destructive) {
                        queueToDelete = queue
                        showingDeleteConfirmation = true
                    }
                    .buttonStyle(QuietButtonStyle(tone: AppTheme.Palette.danger))
                }
            }
            .padding(.horizontal, 20)
            .frame(height: MainWindowMetrics.libraryHeaderHeight)

            ThemeHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    queueRules(queue)
                    displayBindings()
                    wallpaperItems(queue)
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func queueRules(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ThemeSectionHeader(title: "播放规则")
            HStack {
                TextField("队列名称", text: Binding(
                    get: { queue.name },
                    set: { value in update(queue) { $0.name = value } }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(queue.isDefault)
                .frame(maxWidth: 240)
                Picker("排序", selection: Binding(
                    get: { queue.sortMode },
                    set: { value in update(queue) { $0.setSortMode(value) } }
                )) {
                    ForEach(QueueSortMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .frame(width: 150)
            }
            HStack {
                Picker("播放", selection: Binding(
                    get: { queue.playbackMode },
                    set: { value in update(queue) { $0.playbackMode = value } }
                )) {
                    ForEach(QueuePlaybackMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("完成后", selection: Binding(
                    get: { queue.completionBehavior },
                    set: { value in update(queue) { $0.completionBehavior = value } }
                )) {
                    ForEach(QueueCompletionBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                Picker("转场", selection: Binding(
                    get: { queue.transition },
                    set: { value in update(queue) { $0.transition = value } }
                )) {
                    Text("切换").tag(WallpaperTransitionEffect.cut)
                    Text("淡入淡出").tag(WallpaperTransitionEffect.crossfade)
                }
            }
            HStack(spacing: 12) {
                Text("切换时机")
                Picker("切换时机", selection: Binding(
                    get: { queue.advanceMode },
                    set: { value in update(queue) { $0.advanceMode = value } }
                )) {
                    ForEach(QueueAdvanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer(minLength: 0)
            }
            Text(queue.advanceMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(queue.advanceMode == .fixedInterval ? "切换时长" : "图片/网页时长")
                TextField("秒", value: Binding(
                    get: { queue.defaultIntervalSeconds },
                    set: { value in update(queue) { $0.defaultIntervalSeconds = value } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                Text("秒（单项可单独覆盖）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .themeInsetSurface()
    }

    private func displayBindings() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ThemeSectionHeader(title: "显示器队列槽位")
            Text("默认模式只使用不含隐藏壁纸的队列；隐藏模式只使用含隐藏壁纸的队列。队列类型变化后请重新指定槽位。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.displayService.displays.isEmpty {
                Text("当前没有可用显示器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.displayService.displays) { display in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "display")
                            Text(display.name)
                            Spacer()
                            Text(model.showsHiddenWallpapers ? "当前：隐藏模式" : "当前：默认模式")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text("默认模式")
                                .font(.caption)
                                .frame(width: 64, alignment: .leading)
                            Picker("默认模式", selection: Binding<UUID>(
                                get: {
                                    model.queueSlotID(for: display.id, kind: .normal)
                                        ?? PlaybackQueue.defaultQueue.id
                                },
                                set: { queueID in
                                    guard let queue = model.wallpaperManager.queue(with: queueID) else { return }
                                    model.setQueueSlot(.normal, queue: queue, for: display.id)
                                }
                            )) {
                                ForEach(model.queues(for: .normal)) { candidate in
                                    Text(candidate.name).tag(candidate.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)

                            Text("隐藏模式")
                                .font(.caption)
                                .frame(width: 64, alignment: .leading)
                            Picker("隐藏模式", selection: Binding<UUID?>(
                                get: { model.queueSlotID(for: display.id, kind: .hidden) },
                                set: { queueID in
                                    let queue = queueID.flatMap { model.wallpaperManager.queue(with: $0) }
                                    model.setQueueSlot(.hidden, queue: queue, for: display.id)
                                }
                            )) {
                                Text("无").tag(nil as UUID?)
                                ForEach(model.queues(for: .hidden)) { candidate in
                                    Text(candidate.name).tag(Optional(candidate.id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                        if !model.queueSlotIsValid(for: display.id, kind: .normal) {
                            Text("默认槽位指向了含隐藏壁纸的队列，请重新指定。")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Palette.warning)
                        }
                        if let hiddenID = model.queueSlotID(for: display.id, kind: .hidden),
                           let hiddenQueue = model.wallpaperManager.queue(with: hiddenID),
                           model.queueKind(hiddenQueue) != .hidden {
                            Text("隐藏槽位指向了不含隐藏壁纸的队列，请重新指定。")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Palette.warning)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(16)
        .themeInsetSurface()
    }

    private func wallpaperItems(_ queue: PlaybackQueue) -> some View {
        let hasHiddenMembers = !model.showsHiddenWallpapers && queue.wallpaperIDs.contains { id in
            model.wallpapers.first(where: { $0.id == id })?.isHidden == true
        }
        let visibleEntries = queue.wallpaperIDs.enumerated().filter { _, id in
            guard let item = model.wallpapers.first(where: { $0.id == id }) else { return true }
            return model.isWallpaperVisible(item)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ThemeSectionHeader(title: "队列内容")
                Spacer()
                Text("\(visibleEntries.count) 项")
                    .font(AppTheme.Typography.mono(9.5))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            if hasHiddenMembers {
                Label("队列包含隐藏壁纸，解锁后可编辑成员；播放时会自动跳过。", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.warning)
            }
            if visibleEntries.isEmpty {
                Text(hasHiddenMembers ? "当前没有可显示的队列成员。" : "队列为空。可以在壁纸卡片上右键，选择“添加到播放队列”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(visibleEntries.enumerated()), id: \.offset) { displayIndex, entry in
                    let id = entry.element
                    if let item = model.wallpapers.first(where: { $0.id == id }) {
                        HStack(spacing: 10) {
                            Text("\(displayIndex + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Image(systemName: icon(for: item))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.type.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("默认", value: Binding(
                                get: { queue.intervalOverride(for: id) },
                                set: { value in update(queue) { $0.setIntervalOverride(value, for: id) } }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                            .disabled(hasHiddenMembers)
                            Text("秒")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                model.removeWallpapers([id], from: queue.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(hasHiddenMembers)
                            .help("从队列移除")
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("已删除的壁纸（\(id.uuidString.prefix(8))）")
                            .foregroundStyle(AppTheme.Palette.danger)
                    }
                }
                .onMove { source, destination in
                    guard !hasHiddenMembers,
                          let current = model.queueLibrary.first(where: { $0.id == queue.id }) else { return }
                    let sourceIndex = source.first ?? 0
                    model.moveWallpaper(in: current, from: sourceIndex, to: destination)
                }
            }
        }
        .padding(16)
        .themeInsetSurface()
    }

    private func visibleWallpaperCount(_ queue: PlaybackQueue) -> Int {
        guard !model.showsHiddenWallpapers else { return queue.wallpaperIDs.count }
        return queue.wallpaperIDs.reduce(into: 0) { count, id in
            guard let item = model.wallpapers.first(where: { $0.id == id }) else {
                count += 1
                return
            }
            if model.isWallpaperVisible(item) { count += 1 }
        }
    }

    private func update(_ queue: PlaybackQueue, _ change: (inout PlaybackQueue) -> Void) {
        var updated = queue
        change(&updated)
        _ = model.wallpaperManager.updateQueue(updated)
    }

    private func icon(for item: WallpaperItem) -> String {
        switch item.type {
        case .image: return "photo"
        case .video: return "film"
        case .web: return "safari"
        }
    }
}

private struct NewQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let createAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建播放队列")
                .font(.title3.weight(.semibold))
            TextField("队列名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        createAction(trimmed)
        dismiss()
    }
}

private extension WallpaperType {
    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .web: return "网页"
        }
    }
}
