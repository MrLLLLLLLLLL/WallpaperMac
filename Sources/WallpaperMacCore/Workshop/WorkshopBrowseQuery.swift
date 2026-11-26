import Foundation

/// How a Workshop browse page is ordered. The raw value is Steam's
/// `browsesort` query value; `days` only applies to `trending`.
public enum WorkshopBrowseSort: String, CaseIterable, Identifiable, Sendable {
    case trending = "trend"
    case topRated = "toprated"
    case mostSubscribed = "totaluniquesubscribers"
    case newest = "mostrecent"
    case recentlyUpdated = "lastupdated"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trending: return "热门趋势"
        case .topRated: return "好评最多"
        case .mostSubscribed: return "订阅最多"
        case .newest: return "最新发布"
        case .recentlyUpdated: return "最近更新"
        }
    }

    /// Trending is windowed; the other sorts ignore `days`.
    public var days: Int { 30 }
}

/// Age-rating filter matching Wallpaper Engine's own Workshop filter list.
/// Steam exposes these as tags on every item.
public enum WorkshopAgeRating: String, CaseIterable, Identifiable, Sendable {
    case everyone = "Everyone"
    case questionable = "Questionable"
    case mature = "Mature"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .everyone: return "全年龄"
        case .questionable: return "轻度成人"
        case .mature: return "成人"
        }
    }
}

/// Everything the browse grid needs to describe a query. Kept pure so URL
/// construction and default/exclusion rules are unit-testable.
public struct WorkshopBrowseQuery: Equatable, Sendable {
    public var search: String
    public var kindFilter: WorkshopKind?
    public var sort: WorkshopBrowseSort
    public var page: Int
    /// When set, only items carrying this exact rating tag are returned.
    /// Nil shows every rating.
    public var ageRating: WorkshopAgeRating?
    /// Types to exclude even when `kindFilter` is nil. Defaults to
    /// Application and Scene (neither is importable on macOS) so the grid
    /// shows only realistic wallpaper types unless the user asks for them.
    public var excludedKinds: Set<WorkshopKind>

    public init(
        search: String = "",
        kindFilter: WorkshopKind? = nil,
        sort: WorkshopBrowseSort = .trending,
        page: Int = 1,
        ageRating: WorkshopAgeRating? = nil,
        excludedKinds: Set<WorkshopKind> = [.application, .scene]
    ) {
        self.search = search
        self.kindFilter = kindFilter
        self.sort = sort
        self.page = max(1, page)
        self.ageRating = ageRating
        self.excludedKinds = excludedKinds
    }

    /// Tag names Steam accepts in `requiredtags[]` / `excludedtags[]`.
    public var kindTag: String? {
        switch kindFilter {
        case .video: return "Video"
        case .web: return "Web"
        case .scene: return "Scene"
        case .application: return "Application"
        case .unknown, .none: return nil
        }
    }

    public var excludedKindTags: [String] {
        // A type filter already pins the result set; excluding siblings would
        // double up requiredtags AND semantics and hide everything.
        guard kindFilter == nil else { return [] }
        return excludedKinds.compactMap { kind in
            switch kind {
            case .video: return "Video"
            case .web: return "Web"
            case .scene: return "Scene"
            case .application: return "Application"
            case .unknown: return nil
            }
        }.sorted()
    }
}
