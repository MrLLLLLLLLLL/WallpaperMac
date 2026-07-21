import SwiftUI
import WallpaperMacCore

struct QueueManagementView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var selectedQueueID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var queueToDelete: PlaybackQueue?

    var body: some View {
        HStack(spacing: 0) {
            queueList
                .frame(width: 230)
            Divider()
            if let queue = selectedQueue {
                queueDetail(queue)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("还没有播放队列")
                        .font(.headline)
                    Text("创建一个队列后，可以将图片、视频和网页壁纸加入其中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var selectedQueue: PlaybackQueue? {
        guard let selectedQueueID else { return nil }
        return model.queueLibrary.first(where: { $0.id == selectedQueueID })
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("队列库")
                    .font(.headline)
                Spacer()
                Button { model.beginCreateQueue() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建播放队列")
            }
            .padding(16)
            Divider()
            List(selection: $selectedQueueID) {
                ForEach(model.queueLibrary) { queue in
                    HStack(spacing: 9) {
                        Image(systemName: queue.isDefault ? "star.fill" : "list.bullet.rectangle")
                            .foregroundStyle(queue.isDefault ? .yellow : .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queue.name)
                                .lineLimit(1)
                            Text("\(queue.wallpaperIDs.count) 项")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(queue.id)
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
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func queueDetail(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(queue.name)
                        .font(.title2.weight(.semibold))
                    Text(queue.isDefault ? "系统默认队列 · 不可删除" : "命名播放队列")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制") { model.duplicateQueue(queue) }
                    .buttonStyle(.bordered)
                if !queue.isDefault {
                    Button("删除", role: .destructive) {
                        queueToDelete = queue
                        showingDeleteConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    queueRules(queue)
                    displayBindings(queue)
                    wallpaperItems(queue)
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func queueRules(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放规则").font(.headline)
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
            Toggle("视频播放完成后切换下一个壁纸", isOn: Binding(
                get: { queue.advanceAfterVideoCompletion },
                set: { value in update(queue) { $0.advanceAfterVideoCompletion = value } }
            ))
            .toggleStyle(.checkbox)
            .help("启用后，队列中的视频会在实际播放结束时切换；图片和网页仍按队列时长切换。")
            HStack {
                Text("默认时长")
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
    }

    private func displayBindings(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("显示器绑定").font(.headline)
            if model.displayService.displays.isEmpty {
                Text("当前没有可用显示器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.displayService.displays) { display in
                    HStack {
                        Image(systemName: "display")
                        Text(display.name)
                        Spacer()
                        if model.wallpaperManager.activeQueue(for: display.id)?.id == queue.id {
                            Label("当前队列", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Button("应用此队列") {
                                model.setActiveQueue(queue, for: display.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
    }

    private func wallpaperItems(_ queue: PlaybackQueue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("队列内容").font(.headline)
                Spacer()
                Text("\(queue.wallpaperIDs.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if queue.wallpaperIDs.isEmpty {
                Text("队列为空。可以在壁纸卡片上右键，选择“添加到播放队列”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(queue.wallpaperIDs.enumerated()), id: \.element) { index, id in
                    if let item = model.wallpapers.first(where: { $0.id == id }) {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
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
                            Text("秒")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                model.removeWallpapers([id], from: queue.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("从队列移除")
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("已删除的壁纸（\(id.uuidString.prefix(8))）")
                            .foregroundStyle(.red)
                    }
                }
                .onMove { source, destination in
                    guard let current = model.queueLibrary.first(where: { $0.id == queue.id }) else { return }
                    let sourceIndex = source.first ?? 0
                    model.moveWallpaper(in: current, from: sourceIndex, to: destination)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
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
