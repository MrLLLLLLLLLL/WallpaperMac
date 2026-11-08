import Foundation

/// On-disk document for the stable display profiles.
///
/// `profiles` is authoritative once written. The two `unmatchedLegacy` arrays
/// keep pre-profile records that could not be attached to a connected display,
/// so they can be claimed later and still written back to the legacy files for
/// downgrade compatibility.
public struct DisplayProfileDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var profiles: [DisplayProfile]
    public var unmatchedLegacyAssignments: [DisplayAssignment]
    public var unmatchedLegacyBindings: [DisplayPlaybackBinding]

    public init(
        schemaVersion: Int = DisplayProfileDocument.currentSchemaVersion,
        profiles: [DisplayProfile] = [],
        unmatchedLegacyAssignments: [DisplayAssignment] = [],
        unmatchedLegacyBindings: [DisplayPlaybackBinding] = []
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.unmatchedLegacyAssignments = unmatchedLegacyAssignments
        self.unmatchedLegacyBindings = unmatchedLegacyBindings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profiles
        case unmatchedLegacyAssignments
        case unmatchedLegacyBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.profiles = try container.decodeIfPresent([DisplayProfile].self, forKey: .profiles) ?? []
        self.unmatchedLegacyAssignments =
            try container.decodeIfPresent([DisplayAssignment].self, forKey: .unmatchedLegacyAssignments) ?? []
        self.unmatchedLegacyBindings =
            try container.decodeIfPresent([DisplayPlaybackBinding].self, forKey: .unmatchedLegacyBindings) ?? []
    }

    public func profile(withID profileID: String) -> DisplayProfile? {
        profiles.first { $0.profileID == profileID }
    }
}

public struct DisplayProfileMigrationResult: Equatable, Sendable {
    public let document: DisplayProfileDocument
    /// Legacy display ID (`display-<cgid>`) to stable profile ID.
    public let profileIDByLegacyID: [String: String]

    public init(
        document: DisplayProfileDocument,
        profileIDByLegacyID: [String: String]
    ) {
        self.document = document
        self.profileIDByLegacyID = profileIDByLegacyID
    }
}

/// Converts legacy per-display records into stable profiles.
public enum DisplayProfileMigrator {
    /// First migration: claim legacy records for the currently connected
    /// displays and preserve everything else as unmatched.
    public static func migrate(
        legacyAssignments: [DisplayAssignment],
        legacyBindings: [DisplayPlaybackBinding],
        identities: [DisplayIdentity],
        now: Date
    ) -> DisplayProfileMigrationResult {
        var profiles: [DisplayProfile] = []
        var usedProfileIDs = Set<String>()
        var claimedAssignmentIDs = Set<String>()
        var claimedBindingIDs = Set<String>()
        var mapping: [String: String] = [:]

        for identity in identities {
            let legacyID = legacyDisplayID(for: identity)
            // A reboot can swap CGDirectDisplayIDs. Prefer a unique display
            // name from the legacy file, then fall back to the runtime ID.
            let assignment = uniqueAssignment(
                named: identity.localizedName,
                in: legacyAssignments,
                excluding: claimedAssignmentIDs
            ) ?? legacyAssignments.first { $0.id == legacyID }
            let binding = uniqueBinding(
                named: identity.localizedName,
                in: legacyBindings,
                excluding: claimedBindingIDs
            ) ?? legacyBindings.first { $0.displayID == legacyID }
            if let assignment { claimedAssignmentIDs.insert(assignment.id) }
            if let binding { claimedBindingIDs.insert(binding.displayID) }

            let profileID = uniqueProfileID(base: identity.profileID, in: usedProfileIDs)
            usedProfileIDs.insert(profileID)
            mapping[legacyID] = profileID

            profiles.append(
                DisplayProfile(
                    profileID: profileID,
                    identity: identity,
                    lastSeenAt: now,
                    assignment: assignment.map { rekey($0, profileID: profileID, displayName: identity.localizedName) },
                    binding: binding.map { rekey($0, profileID: profileID, displayName: identity.localizedName) }
                )
            )
        }

        let unmatchedAssignments = legacyAssignments.filter { !claimedAssignmentIDs.contains($0.id) }
        let unmatchedBindings = legacyBindings.filter { !claimedBindingIDs.contains($0.displayID) }

        return DisplayProfileMigrationResult(
            document: DisplayProfileDocument(
                profiles: profiles,
                unmatchedLegacyAssignments: unmatchedAssignments,
                unmatchedLegacyBindings: unmatchedBindings
            ),
            profileIDByLegacyID: mapping
        )
    }

    /// Later launches: keep existing profiles, refresh the identity snapshot of
    /// connected displays, create profiles for new displays, and let a display
    /// reconnect claim a matching unmatched legacy record by its runtime ID.
    ///
    /// When a legacy file is newer than the profile document (for example after
    /// a downgrade edited it), its records override the matching connected
    /// profiles so changes made by the older build are not lost. When it is
    /// older, it may still fill profiles that have no assignment/binding yet.
    public static func merge(
        document: DisplayProfileDocument,
        identities: [DisplayIdentity],
        legacyAssignments: [DisplayAssignment]? = nil,
        legacyBindings: [DisplayPlaybackBinding]? = nil,
        overwriteAssignments: Bool = true,
        overwriteBindings: Bool = true,
        now: Date
    ) -> DisplayProfileDocument {
        var profiles = document.profiles
        var unmatchedAssignments = document.unmatchedLegacyAssignments
        var unmatchedBindings = document.unmatchedLegacyBindings
        var claimedAssignmentIDs = Set<String>()
        var claimedBindingIDs = Set<String>()

        for identity in identities {
            let legacyID = legacyDisplayID(for: identity)
            let existingIndex = profileIndex(for: identity, in: profiles)
            let existingProfile = existingIndex.map { profiles[$0] }

            // Name is more reliable than CGDirectDisplayID across a reboot:
            // the runtime number can be reassigned to the other display.
            var overrideAssignment = legacyAssignments.flatMap {
                uniqueAssignment(named: identity.localizedName, in: $0, excluding: claimedAssignmentIDs)
            } ?? legacyAssignments?.first { $0.id == legacyID }
            var overrideBinding = legacyBindings.flatMap {
                uniqueBinding(named: identity.localizedName, in: $0, excluding: claimedBindingIDs)
            } ?? legacyBindings?.first { $0.displayID == legacyID }

            if let assignment = overrideAssignment,
               !acceptsLegacyName(
                   assignment.displayName,
                   for: identity,
                   profileHasData: existingProfile?.assignment != nil,
                   overwriteExisting: overwriteAssignments
               ) {
                overrideAssignment = nil
            }
            if let binding = overrideBinding,
               !acceptsLegacyName(
                   binding.displayName,
                   for: identity,
                   profileHasData: existingProfile?.binding != nil,
                   overwriteExisting: overwriteBindings
               ) {
                overrideBinding = nil
            }

            if let overrideAssignment {
                claimedAssignmentIDs.insert(overrideAssignment.id)
                unmatchedAssignments.removeAll { $0.id == overrideAssignment.id }
            }
            if let overrideBinding {
                claimedBindingIDs.insert(overrideBinding.displayID)
                unmatchedBindings.removeAll { $0.displayID == overrideBinding.displayID }
            }

            if let index = existingIndex {
                profiles[index].identity = identity
                profiles[index].lastSeenAt = now
                if let overrideAssignment {
                    profiles[index].assignment = rekey(
                        overrideAssignment,
                        profileID: profiles[index].profileID,
                        displayName: identity.localizedName
                    )
                }
                if let overrideBinding {
                    profiles[index].binding = rekey(
                        overrideBinding,
                        profileID: profiles[index].profileID,
                        displayName: identity.localizedName
                    )
                }
                continue
            }

            let assignment: DisplayAssignment?
            if let overrideAssignment {
                assignment = overrideAssignment
            } else if let index = uniqueAssignment(
                named: identity.localizedName,
                in: unmatchedAssignments
            ).flatMap({ candidate in unmatchedAssignments.firstIndex(where: { $0.id == candidate.id }) }) {
                assignment = unmatchedAssignments.remove(at: index)
            } else if let index = unmatchedAssignments.firstIndex(where: { $0.id == legacyID }) {
                assignment = unmatchedAssignments.remove(at: index)
            } else {
                assignment = nil
            }

            let binding: DisplayPlaybackBinding?
            if let overrideBinding {
                binding = overrideBinding
            } else if let index = uniqueBinding(
                named: identity.localizedName,
                in: unmatchedBindings
            ).flatMap({ candidate in unmatchedBindings.firstIndex(where: { $0.displayID == candidate.displayID }) }) {
                binding = unmatchedBindings.remove(at: index)
            } else if let index = unmatchedBindings.firstIndex(where: { $0.displayID == legacyID }) {
                binding = unmatchedBindings.remove(at: index)
            } else {
                binding = nil
            }

            var usedProfileIDs = Set(profiles.map(\.profileID))
            let profileID = uniqueProfileID(base: identity.profileID, in: usedProfileIDs)
            usedProfileIDs.insert(profileID)

            profiles.append(
                DisplayProfile(
                    profileID: profileID,
                    identity: identity,
                    lastSeenAt: now,
                    assignment: assignment.map { rekey($0, profileID: profileID, displayName: identity.localizedName) },
                    binding: binding.map { rekey($0, profileID: profileID, displayName: identity.localizedName) }
                )
            )
        }

        if let legacyAssignments {
            for record in legacyAssignments where !claimedAssignmentIDs.contains(record.id) {
                if let index = unmatchedAssignments.firstIndex(where: { $0.id == record.id }) {
                    unmatchedAssignments[index] = record
                } else {
                    unmatchedAssignments.append(record)
                }
            }
        }
        if let legacyBindings {
            for record in legacyBindings where !claimedBindingIDs.contains(record.displayID) {
                if let index = unmatchedBindings.firstIndex(where: { $0.displayID == record.displayID }) {
                    unmatchedBindings[index] = record
                } else {
                    unmatchedBindings.append(record)
                }
            }
        }

        return DisplayProfileDocument(
            schemaVersion: DisplayProfileDocument.currentSchemaVersion,
            profiles: profiles,
            unmatchedLegacyAssignments: unmatchedAssignments,
            unmatchedLegacyBindings: unmatchedBindings
        )
    }

    public static func legacyDisplayID(for identity: DisplayIdentity) -> String {
        "display-\(identity.cgDisplayID)"
    }

    // MARK: - Helpers

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniqueAssignment(
        named name: String,
        in assignments: [DisplayAssignment],
        excluding excluded: Set<String> = []
    ) -> DisplayAssignment? {
        let target = normalizedName(name)
        guard !target.isEmpty else { return nil }
        let matches = assignments.filter {
            !excluded.contains($0.id) && normalizedName($0.displayName) == target
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func uniqueBinding(
        named name: String,
        in bindings: [DisplayPlaybackBinding],
        excluding excluded: Set<String> = []
    ) -> DisplayPlaybackBinding? {
        let target = normalizedName(name)
        guard !target.isEmpty else { return nil }
        let matches = bindings.filter {
            !excluded.contains($0.displayID) && normalizedName($0.displayName) == target
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A legacy record may only override a stable profile when it clearly
    /// belongs to this physical display. Runtime IDs are not trusted here:
    /// they can be reassigned to another display after a reboot.
    private static func acceptsLegacyName(
        _ legacyName: String,
        for identity: DisplayIdentity,
        profileHasData: Bool,
        overwriteExisting: Bool
    ) -> Bool {
        if profileHasData && !overwriteExisting { return false }
        if normalizedName(legacyName) == normalizedName(identity.localizedName) {
            return true
        }
        // Without a ColorSync UUID the runtime ID is the only identity we
        // have, so allow it to seed a profile that has no data yet.
        return !profileHasData && identity.uuid == nil
    }

    /// Finds the profile for a live display. UUID is authoritative; the
    /// remaining tiers handle displays whose UUID is missing or changed.
    private static func profileIndex(
        for identity: DisplayIdentity,
        in profiles: [DisplayProfile]
    ) -> Int? {
        if let index = profiles.firstIndex(where: { $0.profileID == identity.profileID }) {
            return index
        }
        if let uuid = identity.uuid, !uuid.isEmpty,
           let index = profiles.firstIndex(where: { $0.identity.uuid == uuid }) {
            return index
        }
        if let serial = identity.serialNumber, serial != 0 {
            let matches = profiles.indices.filter { index in
                let profile = profiles[index]
                return profile.identity.serialNumber == serial
                    && profile.identity.vendorNumber == identity.vendorNumber
                    && profile.identity.modelNumber == identity.modelNumber
            }
            if matches.count == 1 { return matches[0] }
        }
        let name = normalizedName(identity.localizedName)
        if !name.isEmpty {
            let matches = profiles.indices.filter { index in
                let profile = profiles[index]
                return normalizedName(profile.identity.localizedName) == name
                    && profile.identity.geometry.pixelWidth == identity.geometry.pixelWidth
                    && profile.identity.geometry.pixelHeight == identity.geometry.pixelHeight
            }
            if matches.count == 1 { return matches[0] }
        }
        // cgid-* profiles have no hardware UUID; match their runtime ID last.
        let cgidMatches = profiles.indices.filter {
            profiles[$0].identity.uuid == nil
                && profiles[$0].identity.cgDisplayID == identity.cgDisplayID
        }
        return cgidMatches.count == 1 ? cgidMatches[0] : nil
    }

    private static func rekey(
        _ assignment: DisplayAssignment,
        profileID: String,
        displayName: String
    ) -> DisplayAssignment {
        DisplayAssignment(
            id: profileID,
            displayName: displayName,
            isConnected: true,
            wallpaperID: assignment.wallpaperID,
            applicationState: assignment.applicationState
        )
    }

    private static func rekey(
        _ binding: DisplayPlaybackBinding,
        profileID: String,
        displayName: String
    ) -> DisplayPlaybackBinding {
        DisplayPlaybackBinding(
            displayID: profileID,
            displayName: displayName,
            activeQueueID: binding.activeQueueID,
            queueStates: binding.queueStates
        )
    }

    private static func uniqueProfileID(base: String, in used: Set<String>) -> String {
        guard used.contains(base) else { return base }
        var index = 2
        while used.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }
}
