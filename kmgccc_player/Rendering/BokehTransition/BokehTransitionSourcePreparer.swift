//
//  BokehTransitionSourcePreparer.swift
//  myPlayer2
//

import CoreGraphics
import Foundation
import os

struct BokehTransitionSourceFrames: @unchecked Sendable {
    let leading: CoverGradientBlurRenderedFrame
    let centered: CoverGradientBlurRenderedFrame
    let transition: CoverGradientBlurRenderedFrame

    init?(
        leading: CoverGradientBlurRenderedFrame?,
        centered: CoverGradientBlurRenderedFrame?,
        transition: CoverGradientBlurRenderedFrame?
    ) {
        guard let leading,
              let centered,
              let transition,
              leading.placement == .leading,
              centered.placement == .centeredSymmetric,
              transition.placement == .transition,
              leading.artworkChecksum != 0,
              leading.artworkChecksum == centered.artworkChecksum,
              leading.artworkChecksum == transition.artworkChecksum,
              leading.logicalCanvasSize.width > 1,
              leading.logicalCanvasSize.height > 1 else {
            return nil
        }
        self.leading = leading
        self.centered = centered
        self.transition = transition
    }

    func identity(
        renderSize: BokehTransitionRenderSize,
        tier: BokehTransitionRenderTier
    ) -> BokehTransitionSourceIdentity {
        BokehTransitionSourceIdentity(
            artworkChecksum: leading.artworkChecksum,
            leadingRenderKey: leading.renderKey,
            centeredRenderKey: centered.renderKey,
            transitionRenderKey: transition.renderKey,
            renderSize: renderSize,
            tier: tier
        )
    }
}

struct BokehTransitionPreparedSourceSet: @unchecked Sendable {
    let identity: BokehTransitionSourceIdentity
    let leading: CGImage
    let centered: CGImage
    let transition: CGImage
    let transitionCanvasSizeRatio: CGSize
}

/// Converts the three completed Core Image renders to stable, small source
/// images before the next transition. Generation checks make it impossible to
/// publish a mixed-artwork or mixed-geometry texture set.
@MainActor
final class BokehTransitionSourcePreparer {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kmgccc.player",
        category: "BokehTransition"
    )

    private var generation = 0
    private var task: Task<Void, Never>?

    private(set) var currentSourceSet: BokehTransitionPreparedSourceSet?

    deinit {
        task?.cancel()
    }

    func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        currentSourceSet = nil
    }

    func prepare(
        frames: BokehTransitionSourceFrames,
        renderSize: BokehTransitionRenderSize,
        tier: BokehTransitionRenderTier,
        onReady: @escaping @MainActor (BokehTransitionPreparedSourceSet) -> Void
    ) {
        let identity = frames.identity(renderSize: renderSize, tier: tier)
        if currentSourceSet?.identity == identity { return }

        generation &+= 1
        let expectedGeneration = generation
        task?.cancel()

        task = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.prepare(frames: frames, identity: identity)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.generation == expectedGeneration,
                  let prepared else { return }

            self.currentSourceSet = prepared
            #if DEBUG
            self.logger.debug(
                "Bokeh source preparation complete; \(prepared.identity.renderSize.width)x\(prepared.identity.renderSize.height)"
            )
            #endif
            onReady(prepared)
        }
    }

    private nonisolated static func prepare(
        frames: BokehTransitionSourceFrames,
        identity: BokehTransitionSourceIdentity
    ) -> BokehTransitionPreparedSourceSet? {
        guard !Task.isCancelled else { return nil }
        let viewport = frames.leading.logicalCanvasSize
        let transitionSize = frames.transition.logicalCanvasSize
        guard viewport.width > 1, viewport.height > 1,
              transitionSize.width > 1, transitionSize.height > 1 else { return nil }

        let scale = CGFloat(identity.renderSize.width) / viewport.width
        let transitionTarget = CGSize(
            width: max(16, (transitionSize.width * scale).rounded(.down)),
            height: max(16, (transitionSize.height * scale).rounded(.down))
        )
        let alignedTransitionTarget = CGSize(
            width: Int(transitionTarget.width / 16) * 16,
            height: Int(transitionTarget.height / 16) * 16
        )

        guard let leading = downsample(frames.leading.image, to: identity.renderSize.cgSize),
              !Task.isCancelled,
              let centered = downsample(frames.centered.image, to: identity.renderSize.cgSize),
              !Task.isCancelled,
              let transition = downsample(frames.transition.image, to: alignedTransitionTarget),
              !Task.isCancelled else {
            return nil
        }

        return BokehTransitionPreparedSourceSet(
            identity: identity,
            leading: leading,
            centered: centered,
            transition: transition,
            transitionCanvasSizeRatio: CGSize(
                width: transitionSize.width / viewport.width,
                height: transitionSize.height / viewport.height
            )
        )
    }

    private nonisolated static func downsample(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        return context.makeImage()
    }
}
