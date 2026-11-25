import AVFoundation
import AppKit
import CoreMedia
import WebKit
import WallpaperMacCore

enum WallpaperContentError: Error, LocalizedError {
    case cannotLoadResource(URL)

    var errorDescription: String? {
        switch self {
        case .cannotLoadResource(let url):
            return "无法加载壁纸资源：\(url.isFileURL ? url.path : url.absoluteString)"
        }
    }
}
