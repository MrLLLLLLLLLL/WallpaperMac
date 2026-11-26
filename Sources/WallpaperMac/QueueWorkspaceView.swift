import SwiftUI
import WallpaperMacCore

struct QueueWorkspaceView: View {
    @ObservedObject var model: LibraryViewModel
    let queueID: UUID
    @State private var isPickerPresented = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        if let queue = model.queueLibrary.first(where: { $0.id == queueID }) {
            workspace(queue)
        } else {
            missingQueue
        }
    }

    private func workspace(_ queue: PlaybackQueue) -> some View {
        VStack(spacing: 0) {
            header(queue)
            ThemeHairline()
            HStack(spacing: 0) {
                membersColumn(queue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ThemeVerticalHairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        rulesSection(queue)
                        bindingsSection(queue)
                    }
                    .padding(16)
                }
                .frame(width: 360)
                .background(AppTheme.Palette.panel)
            }
        }
        .background(AppTheme.Palette.canvas)
        .sheet(isPresented: $isPickerPresented) {
            QueueWallpaperPickerSheet(model: model, queue: queue)
        }
        .confirmationDialog("删除播放队列？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.deleteQueue(queue)
                model.destination = .all
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("队列中的壁纸记录不会被删除；正在使用该队列的显示器会切换到默认队列。")
        }
    }

    private func header(_ queue: PlaybackQueue) -> some View {
        let kind = model.queueKind(queue)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(queue.name)
                    .font(AppTheme.Typography.display(21))
                    .foregroundStyle(AppTheme.Palette.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(kind == .hidden ? "隐藏队列" : "普通队列")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(kind == .hidden ? AppTheme.Palette.accent : AppTheme.Palette.textTertiary)
                    Text("\(visibleEntries(for: queue).count) 项")
                        .font(AppTheme.Typography.mono(9))
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button("复制") {
                if let copy = model.duplicateQueue(queue) {
                    model.destination = .queue(copy.id)
                }
            }
            .buttonStyle(QuietButtonStyle())
            if !queue.isDefault {
                Button("删除", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .buttonStyle(QuietButtonStyle(tone: AppTheme.Palette.danger))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: MainWindowMetrics.libraryHeaderHeight)
    }

    private func membersColumn(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ThemeSectionHeader(title: "队列内容")
                Spacer()
                Button("添加壁纸") { isPickerPresented = true }
                    .buttonStyle(AccentActionButtonStyle(compact: true))
                    .disabled(hasHiddenMembers(for: queue))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            let entries = visibleEntries(for: queue)
            if hasHiddenMembers(for: queue) {
                Label("队列包含隐藏壁纸，解锁隐藏壁纸后可查看和编辑隐藏成员。", systemImage: "eye.slash")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.warning)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if entries.isEmpty {
                emptyMembers(queue)
            } else {
                List {
                    ForEach(entries, id: \.item.id) { entry in
                        memberRow(queue, entry: entry)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { source, destination in
                        move(queue, from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.Palette.canvas)
            }
        }
        .background(AppTheme.Palette.canvas)
    }

    private func memberRow(_ queue: PlaybackQueue, entry: QueueMemberEntry) -> some View {
        let item = entry.item
        let hasHidden = hasHiddenMembers(for: queue)
        return HStack(spacing: 10) {
            Text("\(entry.position + 1)")
                .font(AppTheme.Typography.mono(9))
                .foregroundStyle(AppTheme.Palette.textTertiary)
                .frame(width: 22, alignment: .trailing)
            ThumbnailView(item: item)
                .frame(width: 72, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(AppTheme.Palette.hairline, lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Palette.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(typeName(item.type))
                        .font(AppTheme.Typography.micro)
                    if item.isHidden {
                        Label("已隐藏", systemImage: "eye.slash")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.warning)
                    }
                    if item.availability != .available {
                        Text("不可用")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.danger)
                    }
                }
                .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            Spacer(minLength: 8)
            TextField("默认", value: Binding(
                get: { queue.intervalOverride(for: item.id) },
                set: { value in
                    update(queue) { $0.setIntervalOverride(value, for: item.id) }
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .disabled(hasHidden)
            Text("秒")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
            Button(role: .destructive) {
                model.removeWallpapers([item.id], from: queue.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .disabled(hasHidden)
            .help("从队列移除")
        }
        .padding(.vertical, 4)
    }

    private func emptyMembers(_ queue: PlaybackQueue) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 150, height: 84)
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(AppTheme.Palette.accent)
            }
            Text(hasHiddenMembers(for: queue) ? "队列包含隐藏壁纸" : "队列还是空的")
                .font(AppTheme.Typography.display(18))
                .foregroundStyle(AppTheme.Palette.text)
            Text(hasHiddenMembers(for: queue)
                 ? "解锁隐藏壁纸后可查看和编辑成员。"
                 : "添加图片、视频或网页壁纸，然后调整顺序和时长。")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            // After the library index was rebuilt from thumbnails, queue
            // memberships could not be restored automatically. Surface that
            // possibility only when the library actually has wallpapers;
            // brand-new empty libraries do not need this hint.
            if !hasHiddenMembers(for: queue), !model.wallpapers.isEmpty {
                Text("如果恢复壁纸库前队列中有内容，需要重新添加成员。")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hasHiddenMembers(for: queue) {
                Button("添加壁纸") { isPickerPresented = true }
                    .buttonStyle(AccentActionButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func rulesSection(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ThemeSectionHeader(title: "播放规则")
            VStack(alignment: .leading, spacing: 10) {
                labeled("名称") {
                    TextField("队列名称", text: Binding(
                        get: { queue.name },
                        set: { value in update(queue) { $0.name = value } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(queue.isDefault)
                }
                labeled("排序") {
                    Picker("排序", selection: Binding(
                        get: { queue.sortMode },
                        set: { value in update(queue) { $0.setSortMode(value) } }
                    )) {
                        ForEach(QueueSortMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                labeled("播放") {
                    Picker("播放", selection: Binding(
                        get: { queue.playbackMode },
                        set: { value in update(queue) { $0.playbackMode = value } }
                    )) {
                        ForEach(QueuePlaybackMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                labeled("完成后") {
                    Picker("完成后", selection: Binding(
                        get: { queue.completionBehavior },
                        set: { value in update(queue) { $0.completionBehavior = value } }
                    )) {
                        ForEach(QueueCompletionBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // Random playback has no cycle bookkeeping yet, so
                    // "stop after one cycle" would never trigger. Hide the
                    // choice instead of letting it silently lie.
                    .disabled(queue.playbackMode == .random)
                }
                if queue.playbackMode == .random {
                    Text("随机播放暂不支持“播放一轮后停止”，将一直循环。")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                labeled("转场") {
                    Picker("转场", selection: Binding(
                        get: { queue.transition },
                        set: { value in update(queue) { $0.transition = value } }
                    )) {
                        ForEach(WallpaperTransitionEffect.allCases, id: \.self) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                labeled("切换时机") {
                    Picker("切换时机", selection: Binding(
                        get: { queue.advanceMode },
                        set: { value in update(queue) { $0.advanceMode = value } }
                    )) {
                        ForEach(QueueAdvanceMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Text(queue.advanceMode.detail)
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                labeled(queue.advanceMode == .fixedInterval ? "切换时长" : "图片/网页时长") {
                    HStack(spacing: 6) {
                        TextField("秒", value: Binding(
                            get: { queue.defaultIntervalSeconds },
                            set: { value in update(queue) { $0.defaultIntervalSeconds = value } }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text("秒")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                    }
                }
            }
            .padding(12)
            .themeInsetSurface()
        }
    }

    private func bindingsSection(_ queue: PlaybackQueue) -> some View {
        let kind = model.queueKind(queue)
        return VStack(alignment: .leading, spacing: 10) {
            ThemeSectionHeader(title: "显示器槽位")
            Text("把这条队列绑定到显示器的\(kind == .normal ? "默认" : "隐藏")槽位。两个槽位可在显示器工作区同时配置。")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if model.displayService.displays.isEmpty {
                Text("当前没有可用显示器。")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.displayService.displays) { display in
                        let isBound = model.queueSlotID(for: display.id, kind: kind) == queue.id
                        HStack(spacing: 8) {
                            Image(systemName: "display")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display.name)
                                    .font(AppTheme.Typography.body)
                                    .foregroundStyle(AppTheme.Palette.text)
                                    .lineLimit(1)
                                Text(isBound ? "已用于\(kind == .normal ? "默认" : "隐藏")槽位" : "未使用此队列")
                                    .font(AppTheme.Typography.micro)
                                    .foregroundStyle(isBound ? AppTheme.Palette.applied : AppTheme.Palette.textTertiary)
                            }
                            Spacer(minLength: 4)
                            if !isBound {
                                Button(kind == .normal ? "设为默认" : "设为隐藏") {
                                    _ = model.setQueueSlot(kind, queue: queue, for: display.id)
                                }
                                .buttonStyle(QuietButtonStyle(compact: true))
                            } else {
                                ThemeStatusDot(color: AppTheme.Palette.applied, size: 4)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if display.id != model.displayService.displays.last?.id {
                            ThemeHairline()
                        }
                    }
                }
                .themeInsetSurface()
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
            content()
        }
    }

    private func update(_ queue: PlaybackQueue, _ change: (inout PlaybackQueue) -> Void) {
        var updated = queue
        change(&updated)
        if !model.wallpaperManager.updateQueue(updated) {
            // Surface that the edit did not persist instead of silently doing
            // nothing when queue persistence is blocked or the queue vanished.
            if model.wallpaperManager.isQueuePersistenceBlocked {
                model.lastError = model.wallpaperManager.queueLoadError
                    ?? "队列文件损坏，已暂停保存以保护原数据；本次修改未生效。"
            } else {
                model.lastError = "保存队列修改失败，请重试。"
            }
        }
    }

    private func move(_ queue: PlaybackQueue, from source: IndexSet, to destination: Int) {
        guard !hasHiddenMembers(for: queue),
              visibleEntries(for: queue).count == queue.wallpaperIDs.count,
              let sourceIndex = source.first else { return }
        model.moveWallpaper(in: queue, from: sourceIndex, to: destination)
    }

    private func hasHiddenMembers(for queue: PlaybackQueue) -> Bool {
        guard !model.showsHiddenWallpapers else { return false }
        return queue.wallpaperIDs.contains { id in
            model.wallpapers.first(where: { $0.id == id })?.isHidden == true
        }
    }

    private func visibleEntries(for queue: PlaybackQueue) -> [QueueMemberEntry] {
        queue.wallpaperIDs.enumerated().compactMap { index, id in
            guard let item = model.wallpapers.first(where: { $0.id == id }),
                  model.isWallpaperVisible(item) else { return nil }
            return QueueMemberEntry(position: index, item: item)
        }
    }

    private func typeName(_ type: WallpaperType) -> String {
        switch type {
        case .image: return "图片"
        case .video: return "视频"
        case .web: return "网页"
        }
    }

    private var missingQueue: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AppTheme.Palette.textTertiary)
            Text("队列不存在")
                .font(AppTheme.Typography.display(18))
                .foregroundStyle(AppTheme.Palette.text)
            Text("它可能已被删除。")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Button("返回壁纸库") { model.destination = .all }
                .buttonStyle(AccentActionButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Palette.canvas)
    }
}

private struct QueueMemberEntry {
    let position: Int
    let item: WallpaperItem
}

struct QueueWallpaperPickerSheet: View {
    @ObservedObject var model: LibraryViewModel
    let queue: PlaybackQueue
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: Set<UUID> = []

    private var existingIDs: Set<UUID> { Set(queue.wallpaperIDs) }

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
                Text("添加壁纸")
                    .font(AppTheme.Typography.display(20))
                    .foregroundStyle(AppTheme.Palette.text)
                Text("到 \(queue.name)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
            .padding(20)

            ThemeHairline()

            HStack(spacing: 12) {
                ThemeSearchField(placeholder: "搜索壁纸", text: $search, width: 260)
                Spacer()
                Text("已选 \(selected.count) 项")
                    .font(AppTheme.Typography.mono(9.5))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                Button("添加") {
                    model.addWallpapers(selected, to: queue.id)
                    dismiss()
                }
                .buttonStyle(AccentActionButtonStyle(compact: true))
                .disabled(selected.isEmpty)
            }
            .padding(16)

            if items.isEmpty {
                Text("没有可添加的壁纸")
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
                            let isExisting = existingIDs.contains(item.id)
                            let isSelected = selected.contains(item.id)
                            Button {
                                guard !isExisting else { return }
                                if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ThumbnailView(item: item)
                                        .frame(height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                                                .stroke(
                                                    isSelected
                                                        ? AppTheme.Palette.accent
                                                        : AppTheme.Palette.hairline,
                                                    lineWidth: isSelected ? 1.5 : 1
                                                )
                                        )
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: isExisting ? "checkmark.circle" : (isSelected ? "checkmark.circle.fill" : "circle"))
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(
                                                    isExisting
                                                        ? AppTheme.Palette.textTertiary
                                                        : (isSelected ? AppTheme.Palette.accent : AppTheme.Palette.text.opacity(0.8))
                                                )
                                                .padding(7)
                                        }
                                    Text(item.name)
                                        .font(AppTheme.Typography.micro)
                                        .foregroundStyle(isExisting ? AppTheme.Palette.textTertiary : AppTheme.Palette.textSecondary)
                                        .lineLimit(1)
                                    if isExisting {
                                        Text("已在队列")
                                            .font(AppTheme.Typography.mono(8))
                                            .foregroundStyle(AppTheme.Palette.textTertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isExisting)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 760, height: 580)
        .background(AppTheme.Palette.canvas)
        .tint(AppTheme.Palette.accent)
    }
}

struct NewQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let createAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建播放队列")
                .font(AppTheme.Typography.display(20))
                .foregroundStyle(AppTheme.Palette.text)
            TextField("队列名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Button("创建") { create() }
                    .buttonStyle(AccentActionButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(AppTheme.Palette.canvas)
        .tint(AppTheme.Palette.accent)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        createAction(trimmed)
        dismiss()
    }
}
