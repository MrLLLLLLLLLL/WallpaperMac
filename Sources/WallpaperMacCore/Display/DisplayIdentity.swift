import Foundation

/// Screen geometry captured at topology time. Matching ignores geometry; it
/// exists so arrangement and resolution changes can be applied to an existing
/// session without recreating its player.
public struct DisplayGeometry: Codable, Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        originX: Double,
        originY: Double,
        width: Double,
        height: Double,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Hardware identity of one display as seen at runtime.
///
/// `uuid` comes from ColorSync (`CGDisplayCreateUUIDFromDisplayID`) and is the
/// preferred persistent key. It can be nil for virtual displays or adapters,
/// so vendor/model/serial and the runtime display number are kept as fallbacks.
public struct DisplayIdentity: Codable, Equatable, Sendable {
    public let uuid: String?
    public let cgDisplayID: UInt32
    public let vendorNumber: UInt32?
    public let modelNumber: UInt32?
    public let serialNumber: UInt32?
    public let localizedName: String
    public let geometry: DisplayGeometry
    public let isBuiltIn: Bool

    public init(
        uuid: String?,
        cgDisplayID: UInt32,
        vendorNumber: UInt32?,
        modelNumber: UInt32?,
        serialNumber: UInt32?,
        localizedName: String,
        geometry: DisplayGeometry,
        isBuiltIn: Bool
    ) {
        self.uuid = uuid
        self.cgDisplayID = cgDisplayID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.localizedName = localizedName
        self.geometry = geometry
        self.isBuiltIn = isBuiltIn
    }

    /// Stable identifier for a new profile. Matched profiles keep their own ID.
    public var profileID: String {
        if let uuid, !uuid.isEmpty {
            return "uuid-\(uuid)"
        }
        return "cgid-\(cgDisplayID)"
    }
}

/// Per-display overrides. `nil` means "follow the global setting".
public struct DisplayPlaybackSettings: Codable, Equatable, Sendable {
    public var isMuted: Bool?
    public var loops: Bool?
    public var fitMode: WallpaperFitMode?
    public var pauseOnBattery: Bool?
    public var pauseInFullScreen: Bool?
    public var webInteractionEnabled: Bool?

    public init(
        isMuted: Bool? = nil,
        loops: Bool? = nil,
        fitMode: WallpaperFitMode? = nil,
        pauseOnBattery: Bool? = nil,
        pauseInFullScreen: Bool? = nil,
        webInteractionEnabled: Bool? = nil
    ) {
        self.isMuted = isMuted
        self.loops = loops
        self.fitMode = fitMode
        self.pauseOnBattery = pauseOnBattery
        self.pauseInFullScreen = pauseInFullScreen
        self.webInteractionEnabled = webInteractionEnabled
    }
}

/// Persisted state for one physical display, keyed by a stable profile ID.
///
/// `assignment` and `binding` are optional while the topology model is being
/// rolled out; phase 2 moves the existing per-display state into them.
public struct DisplayProfile: Codable, Equatable, Sendable, Identifiable {
    public let profileID: String
    public var identity: DisplayIdentity
    public var displayNameOverride: String?
    public var lastSeenAt: Date
    public var needsReview: Bool
    public var assignment: DisplayAssignment?
    public var binding: DisplayPlaybackBinding?
    public var settings: DisplayPlaybackSettings

    public var id: String { profileID }

    public var displayName: String {
        if let displayNameOverride, !displayNameOverride.isEmpty {
            return displayNameOverride
        }
        return identity.localizedName
    }

    public init(
        profileID: String,
        identity: DisplayIdentity,
        displayNameOverride: String? = nil,
        lastSeenAt: Date = .distantPast,
        needsReview: Bool = false,
        assignment: DisplayAssignment? = nil,
        binding: DisplayPlaybackBinding? = nil,
        settings: DisplayPlaybackSettings = DisplayPlaybackSettings()
    ) {
        self.profileID = profileID
        self.identity = identity
        self.displayNameOverride = displayNameOverride
        self.lastSeenAt = lastSeenAt
        self.needsReview = needsReview
        self.assignment = assignment
        self.binding = binding
        self.settings = settings
    }
}
