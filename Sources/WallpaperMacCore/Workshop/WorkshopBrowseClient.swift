import Foundation

/// One tile in the Workshop browse grid.
public struct WorkshopBrowseItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let previewURL: URL?
    public let tags: [String]
    public let fileSizeBytes: Int64?
    public let itemDescription: String

    public init(
        id: String,
        title: String,
        previewURL: URL?,
        tags: [String],
        fileSizeBytes: Int64?,
        itemDescription: String
    ) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.tags = tags
        self.fileSizeBytes = fileSizeBytes
        self.itemDescription = itemDescription
    }

    public var kind: WorkshopKind {
        if tags.contains("Application") { return .application }
        if tags.contains("Scene") { return .scene }
        if tags.contains("Video") { return .video }
        if tags.contains("Web") { return .web }
        return .unknown
    }

    /// Steam attaches exactly one of these to every Workshop item.
    public var ageRating: WorkshopAgeRating? {
        if tags.contains("Everyone") { return .everyone }
        if tags.contains("Questionable") { return .questionable }
        if tags.contains("Mature") { return .mature }
        return nil
    }

    /// v1 can import only video and web items.
    public var isImportable: Bool {
        kind == .video || kind == .web
    }
}

public struct WorkshopBrowsePage: Equatable, Sendable {
    public let items: [WorkshopBrowseItem]
    public let page: Int
    public let hasNext: Bool

    public init(items: [WorkshopBrowseItem], page: Int, hasNext: Bool) {
        self.items = items
        self.page = page
        self.hasNext = hasNext
    }
}

/// Fetches Steam's public Workshop browse pages for Wallpaper Engine and
/// enriches the ids with `GetPublishedFileDetails` (title, preview, tags).
/// Browse itself needs no login; steamcommunity.com must be reachable
/// (mainland China typically needs a system proxy for that host).
public actor WorkshopBrowseClient {
    public enum BrowseError: Error, Equatable, Sendable, LocalizedError {
        case network(String)
        case httpStatus(Int)
        case layoutChanged
        case emptyPage

        public var errorDescription: String? {
            switch self {
            case .network(let message):
                return "无法浏览创意工坊：\(message)。steamcommunity.com 在大陆网络下通常需要系统代理。"
            case .httpStatus(let code):
                return "创意工坊页面返回 HTTP \(code)，请稍后重试。"
            case .layoutChanged:
                return "Steam 页面结构已变化，暂时无法解析列表。可以改用条目链接导入。"
            case .emptyPage:
                return "没有更多结果了。"
            }
        }
    }

    public static let appID = 431960
    public static let pageSize = 30

    private let session: URLSession
    private let metadataClient: WorkshopMetadataClient

    public init(session: URLSession = .shared, metadataClient: WorkshopMetadataClient = WorkshopMetadataClient()) {
        self.session = session
        self.metadataClient = metadataClient
    }

    /// Builds the public browse URL from a query. `kindFilter` maps to Steam's
    /// requiredtags (AND semantics); excluded types go to `excludedtags[]`.
    public static func browseURL(for query: WorkshopBrowseQuery) -> URL {
        var items: [(String, String)] = [
            ("appid", String(appID)),
            ("section", "readytouseitems"),
            ("browsesort", query.sort.rawValue),
            ("days", String(query.sort.days)),
            ("searchtext", query.search),
            ("p", String(query.page)),
            ("numperpage", String(pageSize)),
            ("l", "english")
        ]
        if let tag = query.kindTag {
            items.append(("requiredtags[]", tag))
        }
        if let rating = query.ageRating {
            items.append(("requiredtags[]", rating.rawValue))
        }
        items.append(contentsOf: query.excludedKindTags.map { ("excludedtags[]", $0) })
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        var components = URLComponents()
        components.scheme = "https"
        components.host = "steamcommunity.com"
        components.path = "/workshop/browse/"
        components.percentEncodedQuery = items.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name) + "="
                + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
        return components.url!
    }

    /// Convenience wrapper kept for call sites that only need type filtering.
    public static func browseURL(
        search: String,
        page: Int,
        kindFilter: WorkshopKind?
    ) -> URL {
        browseURL(for: WorkshopBrowseQuery(
            search: search,
            kindFilter: kindFilter,
            page: page
        ))
    }

    /// Extracts published-file ids from a browse page in document order.
    /// Markers cover the SSR JSON, escaped JSON.parse literal, and legacy
    /// `data-publishedfileid` tiles — the same needle set WallpaperMachine
    /// uses so a partial markup change still yields ids.
    public static func itemIDs(in html: String, limit: Int = pageSize) -> [String] {
        guard limit > 0 else { return [] }
        let needles = [
            "sharedfiles/filedetails/?id=",
            "\"publishedfileid\":\"",
            "publishedfileid\\\":\\\"",
            "data-publishedfileid=\""
        ]
        let bytes = Array(html.utf8)
        var found: [(offset: Int, id: String)] = []
        for needleText in needles {
            let needle = Array(needleText.utf8)
            guard !needle.isEmpty, bytes.count >= needle.count else { continue }
            var named = Set<String>()
            var from = 0
            while named.count < limit {
                guard let at = firstIndex(of: needle, in: bytes, from: from) else { break }
                from = at + needle.count
                if let id = digits(at: from, in: bytes), named.insert(id).inserted {
                    found.append((at, id))
                }
            }
        }
        var unique = Set<String>()
        var ids: [String] = []
        for entry in found.sorted(by: { $0.offset < $1.offset })
        where unique.insert(entry.id).inserted {
            ids.append(entry.id)
            if ids.count >= limit { break }
        }
        return ids
    }

    /// True when the page still names a next page (pagination control exists
    /// and is not on the last page). Conservative: unknown markup → false.
    public static func hasNextPage(html: String, currentPage: Int) -> Bool {
        // Steam renders p=N+1 links when another page exists.
        let next = "p=\(currentPage + 1)"
        // Avoid matching the current page's own controls.
        let current = "p=\(currentPage)"
        guard let nextRange = html.range(of: next) else { return false }
        // If the only p= occurrence is the current page, no next.
        if html.range(of: current) == nil { return true }
        // Any p=next after the first p=current suggests a next link.
        _ = nextRange
        return html.contains("pagebtn") || html.contains(next)
    }

    /// One browse page: fetch HTML → ids → enrich via details API.
    public func browse(
        search: String,
        page: Int,
        kindFilter: WorkshopKind?
    ) async throws -> WorkshopBrowsePage {
        try await browse(for: WorkshopBrowseQuery(search: search, kindFilter: kindFilter, page: page))
    }

    /// One browse page for a full query (sort, age rating, exclusions).
    public func browse(
        for query: WorkshopBrowseQuery
    ) async throws -> WorkshopBrowsePage {
        let url = Self.browseURL(for: query)
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "WallpaperMac/0.2 (macOS; public Workshop browser)",
            forHTTPHeaderField: "User-Agent"
        )

        let html: Data
        let response: URLResponse
        do {
            (html, response) = try await session.data(for: request)
        } catch {
            throw BrowseError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BrowseError.httpStatus(http.statusCode)
        }
        guard let pageHTML = String(data: html, encoding: .utf8)
            ?? String(data: html, encoding: .isoLatin1) else {
            throw BrowseError.layoutChanged
        }

        let ids = Self.itemIDs(in: pageHTML)
        guard !ids.isEmpty else {
            // First page with no ids is a layout/network problem; later pages
            // legitimately run out of results.
            if query.page <= 1 { throw BrowseError.layoutChanged }
            return WorkshopBrowsePage(items: [], page: query.page, hasNext: false)
        }

        let tiles = try await enrich(ids: ids)
        let hasNext = Self.hasNextPage(html: pageHTML, currentPage: query.page) && tiles.count > 1
        return WorkshopBrowsePage(items: tiles, page: query.page, hasNext: hasNext)
    }

    /// Looks up a single item (paste-a-link path) as a page of one.
    public func lookup(itemID: String) async throws -> WorkshopBrowseItem {
        let meta = try await metadataClient.fetch(itemID: itemID)
        return Self.tile(from: meta)
    }

    private func enrich(ids: [String]) async throws -> [WorkshopBrowseItem] {
        // One batched details call keeps a 30-tile page to a single round trip.
        let metadatas = try await metadataClient.fetchBatch(itemIDs: ids)
        var byID: [String: WorkshopMetadata] = [:]
        for meta in metadatas { byID[meta.itemID] = meta }
        // Preserve page order; skip ids Steam refused to serve.
        return ids.compactMap { id in
            byID[id].map(Self.tile(from:))
        }
    }

    static func tile(from metadata: WorkshopMetadata) -> WorkshopBrowseItem {
        WorkshopBrowseItem(
            id: metadata.itemID,
            title: metadata.title.isEmpty ? metadata.itemID : metadata.title,
            previewURL: metadata.previewURL,
            tags: metadata.tags,
            fileSizeBytes: metadata.fileSizeBytes,
            itemDescription: metadata.itemDescription
        )
    }

    private static func digits(at start: Int, in bytes: [UInt8]) -> String? {
        var end = start
        while end < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]) {
            end += 1
        }
        guard (5...20).contains(end - start), bytes[start] != UInt8(ascii: "0") else { return nil }
        let id = String(decoding: bytes[start..<end], as: UTF8.self)
        return UInt64(id) == nil ? nil : id
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0],
               haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }
}
