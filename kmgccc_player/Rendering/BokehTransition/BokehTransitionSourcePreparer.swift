//
//  BokehTransitionSourcePreparer.swift
//  myPlayer2
//

import AppKit
import CoreGraphics
import Foundation

/// How the transition draws its panorama: the settled layers' profiles,
/// fill and tint, so both ends of the movement match them exactly.
nonisolated struct BokehTransitionSourceStyle: Sendable {
    let leading: CoverProgressiveBlurProfile
    let centered: CoverProgressiveBlurProfile
    let edgeFill: CoverProgressiveBlurRenderer.EdgeFill
    let overlay: CoverProgressiveBlurRenderer.Overlay?
}

/// One square cover. The renderer draws every panorama of the movement
/// from it, so the moving image and the settled layers share one geometry.
nonisolated struct BokehTransitionSourceSet: @unchecked Sendable {
    let identity: BokehTransitionSourceIdentity
    let cover: CGImage
    let style: BokehTransitionSourceStyle
}

/// Decodes and crops the cover off the main actor.
nonisolated struct BokehTransitionSourceRequest: @unchecked Sendable {
    let artworkData: Data?
    let artworkImage: NSImage?
    let viewport: CGSize
    let displayScale: CGFloat
    let checksum: UInt64
    let sourceKey: String
    let tier: BokehTransitionRenderTier
    let style: BokehTransitionSourceStyle

    var renderSize: BokehTransitionRenderSize? {
        BokehTransitionRenderSize.make(
            backingPixelSize: CGSize(
                width: viewport.width * displayScale,
                height: viewport.height * displayScale
            ),
            tier: tier
        )
    }

    func prepare() -> BokehTransitionSourceSet? {
        autoreleasepool {
            guard !Task.isCancelled,
                  viewport.width > 1, viewport.height > 1,
                  let renderSize,
                  let decoded = CoverGradientBlurRenderer.preparedArtworkImage(
                      artworkData: artworkData,
                      artworkImage: artworkImage,
                      targetSize: CGSize(width: viewport.height, height: viewport.height)
                  ),
                  !Task.isCancelled else { return nil }
            return BokehTransitionSourceSet(
                identity: BokehTransitionSourceIdentity(
                    artworkChecksum: checksum,
                    sourceKey: sourceKey,
                    logicalViewportSize: viewport,
                    displayScale: displayScale,
                    renderSize: renderSize,
                    tier: tier
                ),
                cover: MotionArtworkFrameGeometry.centerSquareCrop(decoded),
                style: style
            )
        }
    }
}
