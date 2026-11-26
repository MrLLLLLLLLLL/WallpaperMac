import SwiftUI
import AppKit
import WallpaperMacCore

/// Browse the Wallpaper Engine Workshop with preview tiles, then download and
/// import a selected video/web item. Browsing is anonymous; the login sheet
/// appears only when a download needs a Steam session.
struct SteamWorkshopBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LibraryViewModel

    @State private var searchText = ""
    @State private var kindFilter: WorkshopKind? = nil
    @State private var ageRating: WorkshopAgeRating? = nil
    @State private var sort: WorkshopBrowseSort = .trending
    @State private var page = 1
    @State private var items: [WorkshopBrowseItem] = []
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isNetworkLoadError = false
    @State private var showDownloadLogin = false
    /// Set when the login sheet finishes: success continues the pending download;
    /// cancel/close only dismisses the login sheet, leaving browse open.
    @State private var loginSheetCompleted = false
    @State private var loginSheetCancelled = false
    @State private var pendingDownloadItem: WorkshopBrowseItem?
    /// True when the current login presentation is retrying an expired session.
    /// Recovery requires an explicit onLoggedIn success, never a stale isLoggedIn.
    @State private var isSessionRecoveryLogin = false
    @State private var selected: WorkshopBrowseItem?
    @State private var downloadStatus: String?
    @State private var downloadFraction: Double?
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var downloadErrorIsSessionExpired = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var appeared = false
    @State private var searchDebounce: Task<Void, Never>?

    private let browseClient = WorkshopBrowseClient()
    private let loginService = SteamLoginService()

    private var activeFilterCount: Int {
        var count = 0
        if kindFilter != nil { count += 1 }
        if ageRating != nil { count += 1 }
        if sort != .trending { count += 1 }
        return count
    }

    private var currentQuery: WorkshopBrowseQuery {
        WorkshopBrowseQuery(
            search: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            kindFilter: kindFilter,
            sort: sort,
            page: page,
            ageRating: ageRating
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchBar
            filterBar
            if activeFilterCount > 0 {
                activeFilterStrip
            }

            if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(loadError, systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if isNetworkLoadError {
                        Button(action: openNetworkSettings) {
                            Label("打开网络设置", systemImage: "network")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("检查网络连接和代理配置")
                    }
                }
            }

            if isDownloading {
                downloadProgressBody
            } else {
                resultsBody
            }

            Text("浏览不需要登录；下载需要已登录且拥有 Wallpaper Engine 的账号。场景与应用类型暂不支持导入。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        // Resizable sheet: min/ideal sizes let the window grow with the
        // content instead of clipping it at a fixed frame.
        .frame(
            minWidth: 700,
            idealWidth: 860,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 660,
            maxHeight: .infinity
        )
        // NSWindow sheets are not user-resizable by default: the SwiftUI frame
        // above only proposes a size, it never adds .resizable to the sheet's
        // styleMask. This hook injects it once the backing window exists so
        // drag-resize and AX sizing both work.
        .background(SheetResizableInjector())
        .onAppear {
            guard !appeared else { return }
            appeared = true
            // Browsing is anonymous; only downloading requires a Steam session.
            reload()
        }
        .onDisappear {
            // Closing the sheet during an active download must not leave an
            // invisible SteamCMD job running.
            cancelDownload()
        }
        .sheet(isPresented: $showDownloadLogin, onDismiss: {
            Task { @MainActor in
                let succeeded = loginSheetCompleted
                let cancelled = loginSheetCancelled
                let wasRecovery = isSessionRecoveryLogin
                loginSheetCompleted = false
                loginSheetCancelled = false
                isSessionRecoveryLogin = false
                if wasRecovery {
                    // Session-expiry recovery: only an explicit login success
                    // may retry. A stale isLoggedIn must not trigger it, and
                    // cancel/orphaned dismissal keeps the error view visible.
                    if succeeded, let item = pendingDownloadItem {
                        pendingDownloadItem = nil
                        startDownload(item)
                    }
                    return
                }
                let loggedIn = await loginService.isLoggedIn
                if succeeded || loggedIn, let item = pendingDownloadItem {
                    pendingDownloadItem = nil
                    startDownload(item)
                } else {
                    // Cancel or failed login: keep the browse sheet open and
                    // clear only the pending download.
                    pendingDownloadItem = nil
                    if cancelled {
                        downloadStatus = nil
                        downloadFraction = nil
                    }
                }
            }
        }) {
            SteamLoginSheet(
                onLoggedIn: {
                    loginSheetCompleted = true
                    loginSheetCancelled = false
                },
                onCancelled: {
                    loginSheetCancelled = true
                    loginSheetCompleted = false
                }
            )
        }
        .sheet(item: $selected) { item in
            itemDetailSheet(item)
        }
    }

    // MARK: - Header / search / filters

    private var header: some View {
        HStack {
            Text("浏览 Steam 创意工坊")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("关闭") { dismiss() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("按名称搜索，或粘贴工坊链接 / ID", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索创意工坊")
                .onSubmit { reload() }
                .onChange(of: searchText) { _ in
                    // Debounced live search: pasted links are handled on submit.
                    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard WorkshopLink.parse(trimmed) == nil else { return }
                    searchDebounce?.cancel()
                    searchDebounce = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            page = 1
                            reload()
                        }
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    page = 1
                    reload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.Palette.hairline.opacity(0.35)))
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("类型", selection: $kindFilter) {
                Text("全部类型").tag(WorkshopKind?.none)
                Text("视频").tag(WorkshopKind?.some(.video))
                Text("网页").tag(WorkshopKind?.some(.web))
                Text("场景（暂不支持）").tag(WorkshopKind?.some(.scene))
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            .onChange(of: kindFilter) { _ in applyFilters() }

            Picker("分级", selection: $ageRating) {
                Text("全部分级").tag(WorkshopAgeRating?.none)
                Text("全年龄").tag(WorkshopAgeRating?.some(.everyone))
                Text("轻度成人").tag(WorkshopAgeRating?.some(.questionable))
                Text("成人").tag(WorkshopAgeRating?.some(.mature))
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .onChange(of: ageRating) { _ in applyFilters() }

            Picker("排序", selection: $sort) {
                ForEach(WorkshopBrowseSort.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .onChange(of: sort) { _ in applyFilters() }

            Spacer()

            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新")
            }
        }
    }

    private var activeFilterStrip: some View {
        HStack(spacing: 6) {
            if let kindFilter {
                filterChip(kindLabel(kindFilter)) {
                    self.kindFilter = nil
                    applyFilters()
                }
            }
            if let ageRating {
                filterChip(ageRating.title) {
                    self.ageRating = nil
                    applyFilters()
                }
            }
            if sort != .trending {
                filterChip(sort.title) {
                    sort = .trending
                    applyFilters()
                }
            }
            if activeFilterCount > 1 {
                Button("清除全部") {
                    kindFilter = nil
                    ageRating = nil
                    sort = .trending
                    applyFilters()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
        }
    }

    private func filterChip(_ label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(AppTheme.Palette.accent.opacity(0.15)))
        .foregroundStyle(AppTheme.Palette.accent)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsBody: some View {
        if isLoading && items.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载工坊列表…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else if items.isEmpty && loadError == nil {
            emptyState
        } else {
            gridAndPager
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有匹配的结果")
                .font(.callout.weight(.medium))
            Text("换个关键词、放宽筛选条件，或粘贴具体的工坊链接。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if activeFilterCount > 0 {
                Button("清除筛选") {
                    kindFilter = nil
                    ageRating = nil
                    sort = .trending
                    applyFilters()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 36)
    }

    private var gridAndPager: some View {
        VStack(spacing: 8) {
            // ScrollView owns vertical scrolling; LazyVGrid inside it keeps
            // cell laziness (only visible tiles decode their previews).
            // The pager/action bar sits *outside* the scroll area so it is
            // never clipped by a long result list.
            ScrollView {
                LazyVGrid(
                    // Fixed five flexible columns: the default sheet width
                    // shows exactly five tiles per row, each narrower than the
                    // old adaptive layout; resizing the sheet scales the tiles
                    // instead of changing the column count.
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                    spacing: 10
                ) {
                    ForEach(items) { item in
                        browseTile(item)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button {
                    page = max(1, page - 1)
                    reload()
                } label: {
                    Label("上一页", systemImage: "chevron.left")
                }
                .disabled(page <= 1 || isLoading)

                Text("第 \(page) 页")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Button {
                    page += 1
                    reload()
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                }
                .disabled(!hasNext || isLoading)

                Spacer()

                if let selected, selected.isImportable {
                    Button {
                        download(selected)
                    } label: {
                        Label("下载所选并导入", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                } else if let selected {
                    Text(kindNote(selected))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(items.count) 项结果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func browseTile(_ item: WorkshopBrowseItem) -> some View {
        let isSelected = selected?.id == item.id
        return Button {
            selected = item
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle()
                        .fill(AppTheme.Palette.hairline.opacity(0.4))
                    if let url = item.previewURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            default:
                                ProgressView().controlSize(.small)
                            }
                        }
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected ? AppTheme.Palette.accent : AppTheme.Palette.hairline,
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if let rating = item.ageRating, rating != .everyone {
                        Text(rating == .mature ? "R-18" : "PG-13")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }

                Text(item.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Palette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    kindBadge(item.kind)
                    if let size = item.fileSizeBytes, size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func kindBadge(_ kind: WorkshopKind) -> some View {
        let (text, color): (String, Color) = switch kind {
        case .video: ("视频", .blue)
        case .web: ("网页", .green)
        case .scene: ("场景", .orange)
        case .application: ("应用", .red)
        case .unknown: ("未知", .secondary)
        }
        return Text(text)
            .font(AppTheme.Typography.micro.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }

    private func kindLabel(_ kind: WorkshopKind) -> String {
        switch kind {
        case .video: return "视频"
        case .web: return "网页"
        case .scene: return "场景（暂不支持）"
        case .application: return "应用"
        case .unknown: return "未知"
        }
    }

    private func kindNote(_ item: WorkshopBrowseItem) -> String {
        switch item.kind {
        case .scene:
            return "场景壁纸依赖 Wallpaper Engine 渲染器，暂不支持导入。"
        case .application:
            return "应用壁纸是 Windows 程序，无法在 macOS 运行。"
        default:
            return "该条目暂不可导入。"
        }
    }

    // MARK: - Download progress

    private var downloadProgressBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView(value: downloadFraction)
                if let downloadFraction {
                    Text("\(Int(downloadFraction * 100))%")
                        .font(.caption.monospaced())
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Text(downloadStatus ?? "正在下载…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let downloadError {
                Label(downloadError, systemImage: "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if downloadErrorIsSessionExpired {
                        Button("重新登录") {
                            // Recovery requires explicit success; do not clear
                            // the error until the login sheet confirms it.
                            isSessionRecoveryLogin = true
                            loginSheetCompleted = false
                            loginSheetCancelled = false
                            showDownloadLogin = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button("返回列表") {
                        resetDownloadUI()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Spacer()
                    Button("取消下载") {
                        cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Detail sheet

    private func itemDetailSheet(_ item: WorkshopBrowseItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(.headline)
                .lineLimit(3)
            HStack(spacing: 8) {
                kindBadge(item.kind)
                if let rating = item.ageRating {
                    Text(rating.title)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppTheme.Palette.hairline.opacity(0.5)))
                }
                Text("ID \(item.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let size = item.fileSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let url = item.previewURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    }
                }
                .frame(maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if !item.itemDescription.isEmpty {
                Text(item.itemDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
            if item.isImportable {
                Button {
                    selected = nil
                    download(item)
                } label: {
                    Label("下载并导入", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text(kindNote(item))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("关闭") { selected = nil }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    // MARK: - Actions

    private func applyFilters() {
        page = 1
        reload()
    }

    private func reload() {
        let queryText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pasted link / bare id jumps straight to that item.
        if let link = WorkshopLink.parse(queryText) {
            loadSingle(link.itemID)
            return
        }
        isLoading = true
        clearLoadError()
        items = []
        let query = currentQuery
        Task { @MainActor in
            do {
                let result = try await browseClient.browse(for: query)
                items = result.items
                hasNext = result.hasNext
                isLoading = false
            } catch let error as WorkshopBrowseClient.BrowseError {
                isLoading = false
                if case .emptyPage = error {
                    items = []
                    hasNext = false
                    clearLoadError()
                } else {
                    setLoadError(error)
                }
            } catch {
                isLoading = false
                setLoadError(error)
            }
        }
    }

    private func clearLoadError() {
        loadError = nil
        isNetworkLoadError = false
    }

    private func setLoadError(_ error: Error) {
        loadError = error.localizedDescription
        isNetworkLoadError = false
        if let browseError = error as? WorkshopBrowseClient.BrowseError,
           case .network = browseError {
            isNetworkLoadError = true
        } else if let metadataError = error as? WorkshopMetadataError,
                  case .network = metadataError {
            isNetworkLoadError = true
        }
    }

    private func openNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadSingle(_ id: String) {
        isLoading = true
        clearLoadError()
        items = []
        Task { @MainActor in
            do {
                let item = try await browseClient.lookup(itemID: id)
                items = [item]
                hasNext = false
                page = 1
                selected = item
                isLoading = false
            } catch {
                isLoading = false
                setLoadError(error)
            }
        }
    }

    private func download(_ item: WorkshopBrowseItem) {
        // Prevent a second tap during the async session check from replacing
        // the pending item or opening another login presentation.
        guard pendingDownloadItem == nil, !isDownloading else { return }
        pendingDownloadItem = item
        selected = nil
        isSessionRecoveryLogin = false
        Task { @MainActor in
            let loggedIn = await loginService.isLoggedIn
            if loggedIn {
                startDownload(item)
            } else {
                // Gate only the download; browsing stays open behind the sheet.
                loginSheetCompleted = false
                loginSheetCancelled = false
                showDownloadLogin = true
            }
        }
    }

    private func startDownload(_ item: WorkshopBrowseItem) {
        isDownloading = true
        downloadError = nil
        downloadErrorIsSessionExpired = false
        downloadStatus = "准备中…"
        downloadFraction = nil
        pendingDownloadItem = item
        downloadTask = Task { @MainActor in
            do {
                let plan = try await model.downloadSteamWorkshopItem(
                    itemID: item.id,
                    username: UserDefaults.standard.string(forKey: SteamSessionStore.usernameDefaultsKey) ?? "",
                    password: "", // session cache: empty password, SteamCMD reuses HOME login
                    steamGuardCode: nil
                ) { status, fraction in
                    Task { @MainActor in
                        guard isDownloading else { return }
                        downloadStatus = status
                        if let fraction { downloadFraction = fraction }
                    }
                }
                isDownloading = false
                downloadStatus = nil
                downloadFraction = nil
                pendingDownloadItem = nil
                switch plan {
                case .video, .webProject:
                    dismiss()
                case .unsupported(let reason):
                    downloadError = reason.userMessage
                    isDownloading = true // stay on progress panel to show error
                }
            } catch is CancellationError {
                resetDownloadUI()
            } catch {
                isDownloading = true
                downloadError = error.localizedDescription
                downloadErrorIsSessionExpired = isSessionExpiredError(error)
                downloadStatus = nil
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// Restores the browse list after cancellation or "返回列表" without
    /// touching the current query, filters, page, or loaded items.
    private func resetDownloadUI() {
        cancelDownload()
        isDownloading = false
        downloadError = nil
        downloadErrorIsSessionExpired = false
        downloadStatus = nil
        downloadFraction = nil
        pendingDownloadItem = nil
        isSessionRecoveryLogin = false
    }

    private func isSessionExpiredError(_ error: Error) -> Bool {
        if let failure = error as? SteamCMDFailure, failure == .sessionExpired {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("会话") || message.contains("登录已过期")
            || message.contains("session") || message.contains("expired")
    }
}

/// Adds `.resizable` to the sheet's backing NSWindow once, so users can
/// drag-resize the browse sheet. SwiftUI's `.frame(minWidth:maxWidth:)`
/// only proposes a size; it never changes the window style mask, which is
/// why the sheet stayed fixed at 700×660 despite the flexible frame.
private struct SheetResizableInjector: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window is assigned after makeNSView returns.
        DispatchQueue.main.async {
            guard let window = view.window, !window.styleMask.contains(.resizable) else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 700, height: 520)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
