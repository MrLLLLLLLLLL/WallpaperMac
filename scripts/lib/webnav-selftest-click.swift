import Foundation

// Posts WallpaperMacWebNavSelfTestClick with view-local x (left) and y (top).
let x = Double(CommandLine.arguments[1]) ?? 0
let y = Double(CommandLine.arguments[2]) ?? 0
let center = DistributedNotificationCenter.default()
center.postNotificationName(
    Notification.Name("WallpaperMacWebNavSelfTestClick"),
    object: nil,
    userInfo: ["x": x, "y": y],
    deliverImmediately: true
)
print("selftest click posted at \(x),\(y)")
