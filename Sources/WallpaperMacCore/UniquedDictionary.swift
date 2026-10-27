import Foundation

/// Builds dictionaries from pairs while tolerating duplicate keys in
/// corrupted on-disk archives. `Dictionary(uniqueKeysWithValues:)` traps on
/// duplicates; this keeps the first occurrence and logs the drop instead.
public enum UniquedDictionary {
    public static func build<Key: Hashable, Value>(
        _ pairs: [(Key, Value)],
        label: String = "entries"
    ) -> [Key: Value] {
        var result: [Key: Value] = [:]
        result.reserveCapacity(pairs.count)
        var duplicateCount = 0
        for (key, value) in pairs {
            if result[key] != nil {
                duplicateCount += 1
                continue
            }
            result[key] = value
        }
        if duplicateCount > 0 {
            NSLog("WallpaperMac: ignored \(duplicateCount) duplicate keys while loading \(label)")
        }
        return result
    }
}
