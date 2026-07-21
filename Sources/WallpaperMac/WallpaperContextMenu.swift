import SwiftUI
import WallpaperMacCore

struct WallpaperContextMenu: View {
    @ObservedObject var model: LibraryViewModel
    let item: WallpaperItem

    private var actionIDs: Set<UUID> {
        if model.isSelectionMode && model.selectedWallpaperIDs.contains(item.id) {
            return model.selectedWallpaperIDs
        }
        return [item.id]
    }

    private var isBatch: Bool { actionIDs.count > 1 }

    private var queuesContainingSelection: [PlaybackQueue] {
        model.queueLibrary.filter { queue in
            queue.wallpaperIDs.contains(where: actionIDs.contains)
        }
    }

    var body: some View {
        Menu("添加到播放队列") {
            if model.queueLibrary.isEmpty {
                Button("新建队列…") { model.beginCreateQueue(for: actionIDs) }
            } else {
                ForEach(model.queueLibrary) { queue in
                    Button(queue.name) {
                        model.addWallpapers(actionIDs, to: queue.id)
                    }
                }
                Divider()
                Button("新建队列…") { model.beginCreateQueue(for: actionIDs) }
            }
        }

        Menu("添加到分组") {
            if model.groups.isEmpty {
                Button("新建分组…") { model.beginCreateGroup(for: actionIDs) }
            } else {
                ForEach(model.groups) { group in
                    Button(group.name) { model.assignWallpapers(actionIDs, to: group.id) }
                }
                Divider()
                Button("新建分组…") { model.beginCreateGroup(for: actionIDs) }
            }
        }

        if !isBatch {
            Menu("应用到显示器") {
                ForEach(model.displayRows.filter(\.isConnected)) { display in
                    Button(display.name) {
                        guard let target = model.wallpapers.first(where: { $0.id == item.id }),
                              let serviceDisplay = model.displayService.displays.first(where: { $0.id == display.id }) else { return }
                        model.apply(item: target, to: serviceDisplay)
                    }
                }
            }
        } else {
            Text("应用到显示器（仅支持单项）")
                .foregroundStyle(.secondary)
        }

        Button(item.isFavorite && !isBatch ? "取消收藏" : "收藏") {
            model.toggleFavorites(for: actionIDs)
        }

        if !isBatch {
            Button("在 Finder 中显示") { model.showInFinder(item) }
        }

        if !queuesContainingSelection.isEmpty {
            Menu("从队列中移除") {
                ForEach(queuesContainingSelection) { queue in
                    Button(queue.name) {
                        model.removeWallpapers(actionIDs, from: queue.id)
                    }
                }
            }
        }

        if !model.groups.isEmpty {
            Button("从分组中移除") { model.assignWallpapers(actionIDs, to: nil) }
        }

        Divider()
        Button(isBatch ? "删除选中的 \(actionIDs.count) 项" : "删除记录", role: .destructive) {
            model.requestDelete(ids: actionIDs)
        }
    }
}
