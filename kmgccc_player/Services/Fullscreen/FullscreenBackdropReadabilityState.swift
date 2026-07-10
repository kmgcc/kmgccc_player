//
//  FullscreenBackdropReadabilityState.swift
//  myPlayer2
//
//  Holds the rendered-backdrop readability maps for the Cover Gradient Blur
//  fullscreen skin: leading (lyrics visible), centered-symmetric (no lyrics),
//  and the oversized transition background. `FullscreenPlayerView` owns one
//  instance and injects it into the fullscreen background subtree; the Cover
//  Blur background bridge writes snapshots here as each background finishes
//  rendering.
//
//  Not a singleton: system fullscreen and embedded fullscreen can run on
//  different canvases, and a shared singleton would let a stale window's
//  snapshot leak into another host.
//
//  See docs/readability-foreground-region-implementation-plan.md section 8.3.
//

import SwiftUI

/// Which Cover Blur background a snapshot describes.
enum CoverGradientBlurReadabilityPlacement: String, Sendable, Equatable {
    case leading
    case centeredSymmetric
    case transition
}

/// One rendered Cover Blur background plus its readability map. For the
/// transition background, `transitionFrames` carries the three representative
/// display frames (start / middle / end of the lyrics-show transition) in
/// fullscreen background coordinates (top-left origin); it is empty for the
/// two static placements.
struct CoverGradientBlurReadabilitySnapshot: Sendable {
    let artworkChecksum: UInt64
    /// Render cache key / config signature, so a stale snapshot cannot be
    /// scored against a newer render config.
    let renderKey: String
    let canvasPixelSize: CGSize
    let placement: CoverGradientBlurReadabilityPlacement
    let readabilityMap: RenderedBackdropReadabilityMap
    let transitionFrames: [CGRect]

    init(
        artworkChecksum: UInt64,
        renderKey: String,
        canvasPixelSize: CGSize,
        placement: CoverGradientBlurReadabilityPlacement,
        readabilityMap: RenderedBackdropReadabilityMap,
        transitionFrames: [CGRect] = []
    ) {
        self.artworkChecksum = artworkChecksum
        self.renderKey = renderKey
        self.canvasPixelSize = canvasPixelSize
        self.placement = placement
        self.readabilityMap = readabilityMap
        self.transitionFrames = transitionFrames
    }
}

@Observable
@MainActor
final class FullscreenBackdropReadabilityState {
    private(set) var artworkChecksum: UInt64 = 0
    private(set) var leading: CoverGradientBlurReadabilitySnapshot?
    private(set) var centered: CoverGradientBlurReadabilitySnapshot?
    private(set) var transition: CoverGradientBlurReadabilitySnapshot?

    /// Called when a new artwork begins rendering. Clears any snapshots that
    /// belong to the previous artwork so a stale map cannot drive the new
    /// track's polarity.
    func beginArtwork(checksum: UInt64) {
        guard checksum != artworkChecksum else { return }
        artworkChecksum = checksum
        leading = nil
        centered = nil
        transition = nil
    }

    /// Accept a freshly rendered snapshot. Stale-artwork and stale-render-key
    /// snapshots are dropped.
    func accept(_ snapshot: CoverGradientBlurReadabilitySnapshot) {
        guard snapshot.artworkChecksum == artworkChecksum else { return }
        switch snapshot.placement {
        case .leading: leading = snapshot
        case .centeredSymmetric: centered = snapshot
        case .transition: transition = snapshot
        }
    }

    func clear() {
        artworkChecksum = 0
        leading = nil
        centered = nil
        transition = nil
    }

    /// True once at least one map for the current artwork is available.
    var hasAnyMap: Bool {
        leading != nil || centered != nil || transition != nil
    }
}

/// Pure value type that computes the fullscreen bottom-controls rectangles
/// in base-canvas (1470×923) top-left coordinates. Centralizes the layout
/// formula that was previously duplicated across `fullscreenMiniPlayerOcclusionRegion`
/// and `bottomControlsRow`. The readability engine consumes normalized
/// versions of these rects (scale-invariant, so any render size maps
/// correctly).
struct FullscreenBottomControlsGeometry: Equatable, Sendable {
    let leadingControlsRect: CGRect
    let miniPlayerRect: CGRect
    let volumeRect: CGRect
    let fullGroupRect: CGRect

    static func make(
        isLeftActionsExpanded: Bool,
        isVolumeExpanded: Bool,
        buttonSize: CGFloat = 60,
        spacing: CGFloat = 20,
        horizontalPadding: CGFloat = 80,
        miniPlayerMaxWidth: CGFloat = 1200,
        miniPlayerPillWidthReduction: CGFloat = 160,
        leadingExpandedWidth: CGFloat = 180,
        leadingCollapsedWidth: CGFloat = 120,
        volumeExpandedWidth: CGFloat = 180,
        volumeCollapsedWidth: CGFloat = 60,
        canvasWidth: CGFloat = 1470,
        canvasHeight: CGFloat = 923,
        bottomPadding: CGFloat = 72
    ) -> FullscreenBottomControlsGeometry {
        let leadingControlsWidth = isLeftActionsExpanded ? leadingExpandedWidth : leadingCollapsedWidth
        let leadingControlsExtraWidth = leadingControlsWidth - leadingCollapsedWidth
        let volumeWidth = isVolumeExpanded ? volumeExpandedWidth : volumeCollapsedWidth
        let volumeExtraWidth = volumeWidth - volumeCollapsedWidth
        let leadingMiniPlayerOriginX = leadingCollapsedWidth + spacing
        let fixedControlWidth = leadingCollapsedWidth + spacing + spacing + volumeCollapsedWidth
        let availableGroupWidth = max(0, canvasWidth - horizontalPadding * 2)
        let collapsedMiniPlayerWidth = max(
            0,
            min(availableGroupWidth - fixedControlWidth, miniPlayerMaxWidth)
                - miniPlayerPillWidthReduction
        )
        let groupWidth = fixedControlWidth + collapsedMiniPlayerWidth
        let currentMiniPlayerWidth = max(
            0,
            collapsedMiniPlayerWidth - leadingControlsExtraWidth - volumeExtraWidth
        )
        let groupOriginX = max(0, (canvasWidth - groupWidth) * 0.5)
        let leadingOriginX = groupOriginX
        let miniPlayerOriginX = groupOriginX + leadingMiniPlayerOriginX + leadingControlsExtraWidth
        let volumeOriginX = max(0, groupOriginX + groupWidth - volumeWidth)
        // Top-left origin: the group sits `bottomPadding` above the canvas bottom.
        let top = canvasHeight - bottomPadding - buttonSize
        return FullscreenBottomControlsGeometry(
            leadingControlsRect: CGRect(x: leadingOriginX, y: top, width: leadingControlsWidth, height: buttonSize),
            miniPlayerRect: CGRect(x: miniPlayerOriginX, y: top, width: currentMiniPlayerWidth, height: buttonSize),
            volumeRect: CGRect(x: volumeOriginX, y: top, width: volumeWidth, height: buttonSize),
            fullGroupRect: CGRect(x: groupOriginX, y: top, width: groupWidth, height: buttonSize)
        )
    }

    /// Normalized sampling regions (top-left origin) for the readability
    /// engine: leading controls, Mini Player, and volume, each expanded by
    /// `expansionPoints` and clamped to the canvas. The three are scored
    /// separately and the engine takes the worst case.
    func readabilityRegions(
        canvasSize: CGSize,
        expansionPoints: CGFloat
    ) -> [NormalizedReadabilityRegion] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        func norm(_ rect: CGRect) -> NormalizedReadabilityRegion {
            let r = rect.insetBy(dx: -expansionPoints, dy: -expansionPoints)
            let x0 = max(0, r.minX)
            let y0 = max(0, r.minY)
            let x1 = min(canvasSize.width, r.maxX)
            let y1 = min(canvasSize.height, r.maxY)
            return NormalizedReadabilityRegion(
                x: x0 / canvasSize.width,
                y: y0 / canvasSize.height,
                width: max(0, (x1 - x0) / canvasSize.width),
                height: max(0, (y1 - y0) / canvasSize.height)
            )
        }
        return [norm(leadingControlsRect), norm(miniPlayerRect), norm(volumeRect)]
    }
}

// MARK: - Environment

import SwiftUI

private struct FullscreenBackdropReadabilityStateKey: EnvironmentKey {
    static let defaultValue: FullscreenBackdropReadabilityState? = nil
}

extension EnvironmentValues {
    /// The Cover Blur fullscreen background subtree writes readability maps
    /// here; `FullscreenPlayerView` reads them to resolve the local control
    /// polarity. nil outside the fullscreen Cover Blur skin.
    var fullscreenBackdropReadabilityState: FullscreenBackdropReadabilityState? {
        get { self[FullscreenBackdropReadabilityStateKey.self] }
        set { self[FullscreenBackdropReadabilityStateKey.self] = newValue }
    }
}
