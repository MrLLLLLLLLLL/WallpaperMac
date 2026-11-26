import SwiftUI
import WallpaperMacCore

/// Browse the Wallpaper Engine Workshop with preview tiles, then download and
/// import a selected video/web item. Opens the login sheet first when there
/// is no Steam session.
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
    @State private var needsLogin = false
    /// Set when the login sheet finishes: success continues browsing;
    /// cancel/close dismisses the browse sheet as well (no re-prompt loop).
    @State private var loginSheetCompleted = false
    @State private var loginSheetCancelled = false
    @State private var selected: WorkshopBrowseItem?
    @State private var downloadStatus: String?
    @State private var downloadFraction: Double?
    @State private var isDownloading = false
    @State private var downloadError: String?
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
                Label(loadError, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 760, height: 620)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            Task { await ensureLoginThenBrowse() }
        }
        .sheet(isPresented: $needsLogin, onDismiss: {
            Task { @MainActor in
                let succeeded = loginSheetCompleted
                let cancelled = loginSheetCancelled
                loginSheetCompleted = false
                loginSheetCancelled = false
                let loggedIn = await loginService.isLoggedIn
                switch SteamLoginGate.decide(
                    isLoggedIn: loggedIn,
                    sheetDismissed: true,
                    loginSucceeded: succeeded,
                    loginCancelled: cancelled
                ) {
                case .showLogin:
                    // Never re-enter from onDismiss — that was the loop.
                    break
                case .continueBrowsing:
                    if items.isEmpty && !isLoading {
                        reload()
                    }
                case .closeBrowse:
                    dismiss()
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
                Text("场景").tag(WorkshopKind?.some(.scene))
            }
            .pickerStyle(.menu)
            .frame(width: 110)
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
            .frame(maxWidth: .infinity, alignment: .center)
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
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 36)
    }

    private var gridAndPager: some View {
        VStack(spacing: 8) {
            // LazyVGrid must own the scroll region: wrapping it in a
            // ScrollView disables cell laziness and decodes every
            // preview at once (visible as UI stutter).
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                spacing: 12
            ) {
                ForEach(items) { item in
                    browseTile(item)
                }
            }
            .padding(.vertical, 4)
            .frame(maxHeight: 380)

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
        case .scene: return "场景"
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
                Button("返回列表") {
                    isDownloading = false
                    self.downloadError = nil
                    downloadStatus = nil
                    downloadFraction = nil
                }
                .buttonStyle(.bordered)
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

    private func ensureLoginThenBrowse() async {
        let loggedIn = await loginService.isLoggedIn
        switch SteamLoginGate.decide(
            isLoggedIn: loggedIn,
            sheetDismissed: false,
            loginSucceeded: false,
            loginCancelled: false
        ) {
        case .showLogin:
            // Only prompt once per gate; onDismiss owns the follow-up so a
            // closed login sheet cannot re-enter this path and loop.
            if !needsLogin {
                loginSheetCompleted = false
                loginSheetCancelled = false
                needsLogin = true
            }
        case .continueBrowsing:
            if items.isEmpty && !isLoading {
                reload()
            }
        case .closeBrowse:
            dismiss()
        }
    }

    private func reload() {
        let queryText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pasted link / bare id jumps straight to that item.
        if let link = WorkshopLink.parse(queryText) {
            loadSingle(link.itemID)
            return
        }
        isLoading = true
        loadError = nil
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
                    loadError = nil
                } else {
                    loadError = error.localizedDescription
                }
            } catch {
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }

    private func loadSingle(_ id: String) {
        isLoading = true
        loadError = nil
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
                loadError = error.localizedDescription
            }
        }
    }

    private func download(_ item: WorkshopBrowseItem) {
        isDownloading = true
        downloadError = nil
        downloadStatus = "准备中…"
        downloadFraction = nil
        selected = nil
        Task { @MainActor in
            do {
                let plan = try await model.downloadSteamWorkshopItem(
                    itemID: item.id,
                    username: UserDefaults.standard.string(forKey: SteamSessionStore.usernameDefaultsKey) ?? "",
                    password: "", // session cache: empty password, SteamCMD reuses HOME login
                    steamGuardCode: nil
                ) { status, fraction in
                    Task { @MainActor in
                        downloadStatus = status
                        if let fraction { downloadFraction = fraction }
                    }
                }
                isDownloading = false
                downloadStatus = nil
                switch plan {
                case .video, .webProject:
                    dismiss()
                case .unsupported(let reason):
                    downloadError = reason.userMessage
                    isDownloading = true // stay on progress panel to show error
                }
            } catch {
                isDownloading = true
                downloadError = error.localizedDescription
                downloadStatus = nil
            }
        }
    }
}
