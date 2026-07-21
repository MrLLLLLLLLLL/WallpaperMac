// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WallpaperMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WallpaperMac", targets: ["WallpaperMac"]),
        .executable(name: "WallpaperMacCoreTests", targets: ["WallpaperMacCoreTests"]),
        .library(name: "WallpaperMacCore", targets: ["WallpaperMacCore"])
    ],
    targets: [
        .executableTarget(
            name: "WallpaperMac",
            dependencies: ["WallpaperMacCore"]
        ),
        .executableTarget(
            name: "WallpaperMacCoreTests",
            dependencies: ["WallpaperMacCore"]
        ),
        .target(
            name: "WallpaperMacCore"
        )
    ]
)
