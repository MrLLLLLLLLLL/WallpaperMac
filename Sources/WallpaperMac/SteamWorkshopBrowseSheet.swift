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

    private let browseClient = WorkshopBrowseClient()
    private let loginService = SteamLoginService()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("浏览 Steam 创意工坊")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }

            HStack(spacing: 8) {
                TextField("搜索，或粘贴工坊链接 / ID", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索创意工坊")
                    .onSubmit { reload() }
                Picker("类型", selection: $kindFilter) {
                    Text("全部").tag(WorkshopKind?.none)
                    Text("视频").tag(WorkshopKind?.some(.video))
                    Text("网页").tag(WorkshopKind?.some(.web))
                    Text("场景").tag(WorkshopKind?.some(.scene))
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                Button("搜索") { reload() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || isDownloading)
            }

            if let loadError {
                Label(loadError, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDownloading {
                downloadProgressBody
            } else if isLoading && items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载工坊列表…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if items.isEmpty && loadError == nil {
                Text("没有结果。换个关键词，或粘贴具体的工坊链接。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(items) { item in
                            browseTile(item)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 380)

                HStack {
                    Button("上一页") {
                        page = max(1, page - 1)
                        reload(append: false)
                    }
                    .disabled(page <= 1 || isLoading)
                    Text("第 \(page) 页")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("下一页") {
                        page += 1
                        reload(append: false)
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
                    }
                }
            }

            Text("浏览不需要登录；下载需要已登录且拥有 Wallpaper Engine 的账号。场景与应用类型初版不支持导入。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 640, height: 560)
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

    // MARK: - Subviews

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

    private func kindNote(_ item: WorkshopBrowseItem) -> String {
        switch item.kind {
        case .scene:
            return "场景壁纸依赖 Wallpaper Engine 渲染器，初版不支持导入。"
        case .application:
            return "应用壁纸是 Windows 程序，无法在 macOS 运行。"
        default:
            return "该条目暂不可导入。"
        }
    }

    private func itemDetailSheet(_ item: WorkshopBrowseItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(.headline)
                .lineLimit(3)
            HStack(spacing: 8) {
                kindBadge(item.kind)
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
                .frame(maxHeight: 220)
            }
            if !item.itemDescription.isEmpty {
                Text(item.itemDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
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
        .frame(width: 460)
    }

    // MARK: - Actions

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

    private func reload(append: Bool = false) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pasted link / bare id jumps straight to that item.
        if let link = WorkshopLink.parse(query) {
            loadSingle(link.itemID)
            return
        }
        isLoading = true
        loadError = nil
        if !append { items = [] }
        let page = self.page
        let filter = kindFilter
        Task { @MainActor in
            do {
                let result = try await browseClient.browse(
                    search: query,
                    page: page,
                    kindFilter: filter
                )
                // Drop session if Steam redirected to sign-in mid-browse.
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
