import AppKit
import AVFoundation
import QuartzCore

/// Creates the presentation layer for each fit mode. Tiling nests two
/// replicators around the same content layer, so AVPlayer/ffmpeg still have a
/// single decoder and one shared content source.
public enum WallpaperLayerLayout {
    public static func make(
        content: CALayer,
        originalSize: CGSize,
        bounds: CGRect,
        mode: WallpaperFitMode,
        contentScale: CGFloat = 1
    ) -> CALayer {
        switch mode {
        case .fill:
            content.frame = bounds
            // Fill covers both axes regardless of asset or display orientation.
            // Landscape 16:9 content in a portrait 16:10 viewport crops its
            // horizontal overflow instead of leaving side bars.
            content.contentsGravity = .resizeAspectFill
            content.setVideoGravityIfSupported(.resizeAspectFill)
            return content
        case .fit:
            content.frame = bounds
            content.contentsGravity = .resizeAspect
            content.setVideoGravityIfSupported(.resizeAspect)
            return content
        case .stretch:
            content.frame = bounds
            content.contentsGravity = .resize
            content.setVideoGravityIfSupported(.resize)
            return content
        case .tile:
            let scale = max(1, contentScale)
            guard let grid = WallpaperTileLayout.grid(
                originalSize: originalSize,
                bounds: bounds.size,
                contentScale: scale
            ) else {
                // Defensive fallback for pathological tiny assets: never
                // allocate an unbounded number of replicated tiles.
                content.frame = bounds
                content.contentsGravity = .resizeAspectFill
                content.setVideoGravityIfSupported(.resizeAspectFill)
                return content
            }
            content.frame = CGRect(origin: .zero, size: grid.tileSize)
            content.contentsScale = scale
            content.contentsGravity = .resizeAspect
            content.setVideoGravityIfSupported(.resizeAspect)

            let row = CAReplicatorLayer()
            row.frame = CGRect(
                origin: .zero,
                size: CGSize(
                    width: grid.tileSize.width * CGFloat(grid.columns),
                    height: grid.tileSize.height
                )
            )
            row.instanceCount = grid.columns
            row.instanceTransform = CATransform3DMakeTranslation(grid.tileSize.width, 0, 0)
            row.addSublayer(content)

            let presentation = CAReplicatorLayer()
            presentation.frame = bounds
            presentation.instanceCount = grid.rows
            presentation.instanceTransform = CATransform3DMakeTranslation(0, grid.tileSize.height, 0)
            presentation.addSublayer(row)
            return presentation
        }
    }
}

private extension CALayer {
    func setVideoGravityIfSupported(_ gravity: AVLayerVideoGravity) {
        if let playerLayer = self as? AVPlayerLayer {
            playerLayer.videoGravity = gravity
        } else if let displayLayer = self as? AVSampleBufferDisplayLayer {
            displayLayer.videoGravity = gravity
        }
    }
}
