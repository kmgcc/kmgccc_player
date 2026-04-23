//
//  BlurredArtworkBackgroundView.swift
//  myPlayer2
//
//  Header halo runtime state + lightweight halo renderer.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class HeaderHaloState {
    private static let anchorEpsilon: CGFloat = 0.5
    private static let scrollEpsilon: CGFloat = 6.0

    private(set) var selectionIdentity: String?
    private(set) var anchor: CGPoint?
    private(set) var scrollDelta: CGFloat = 0

    private var initialScrollOffset: CGFloat?

    private static let parallaxFraction: CGFloat = 0.6
    private static let baseScale: CGFloat = 0.72
    private static let maxScaleGrowth: CGFloat = 0.5
    private static let scaleRange: CGFloat = 500

    var hasValidAnchor: Bool {
        anchor != nil
    }

    var contentSpaceOffset: CGFloat {
        scrollDelta * (Self.parallaxFraction - 1.0)
    }

    var scale: CGFloat {
        let upwardScroll = max(0, -scrollDelta)
        let t = min(upwardScroll / Self.scaleRange, 1.0)
        let eased = 1.0 - pow(1.0 - t, 2.5)
        return Self.baseScale + Self.maxScaleGrowth * eased
    }

    func beginSession(selectionIdentity: String) {
        self.selectionIdentity = selectionIdentity
        self.anchor = nil
        self.initialScrollOffset = nil
        self.scrollDelta = 0
    }

    func clear() {
        selectionIdentity = nil
        anchor = nil
        initialScrollOffset = nil
        scrollDelta = 0
    }

    @discardableResult
    func updateAnchor(bounds: CGRect?) -> Bool {
        guard let bounds, bounds.width > 0, bounds.height > 0 else { return false }
        let nextAnchor = CGPoint(x: bounds.midX, y: bounds.midY)
        if let anchor,
            abs(anchor.x - nextAnchor.x) < Self.anchorEpsilon,
            abs(anchor.y - nextAnchor.y) < Self.anchorEpsilon
        {
            return false
        }
        anchor = nextAnchor
        return true
    }

    @discardableResult
    func updateScroll(offset: CGFloat) -> Bool {
        if initialScrollOffset == nil {
            initialScrollOffset = offset
        }
        let nextDelta = offset - (initialScrollOffset ?? offset)
        if abs(nextDelta - scrollDelta) < Self.scrollEpsilon {
            return false
        }
        scrollDelta = nextDelta
        return true
    }
}

struct HeaderHaloBackgroundView: View {
    let state: HeaderHaloState
    let currentSource: NSImage?
    let incomingSource: NSImage?
    let sourceBlendOpacity: Double
    let presentationOpacity: Double
    var bloomSize: CGFloat = 220 * 4.0

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("HeaderHaloBackgroundView.body")
        Group {
            let hasSource = currentSource != nil || incomingSource != nil
            if let anchor = state.anchor, hasSource {
                let haloY = anchor.y + state.contentSpaceOffset
                LowCostHaloLayerView(
                    currentSource: currentSource,
                    incomingSource: incomingSource,
                    sourceBlendOpacity: sourceBlendOpacity,
                    bloomSize: bloomSize
                )
                .opacity(presentationOpacity)
                .scaleEffect(state.scale)
                .position(x: anchor.x, y: haloY)
            }
        }
        .frame(height: 0)
        .allowsHitTesting(false)
    }
}

struct HeaderFullWindowBackgroundView: View {
    let state: HeaderHaloState
    let currentSource: NSImage?
    let incomingSource: NSImage?
    let sourceBlendOpacity: Double
    let presentationOpacity: Double
    var xOffset: CGFloat = 0
    var yOffset: CGFloat = 0
    var bloomSize: CGFloat = 220 * 4.0

    var body: some View {
        Group {
            let hasSource = currentSource != nil || incomingSource != nil
            if let anchor = state.anchor, hasSource {
                let haloY = anchor.y + state.contentSpaceOffset + yOffset
                LowCostHaloLayerView(
                    currentSource: currentSource,
                    incomingSource: incomingSource,
                    sourceBlendOpacity: sourceBlendOpacity,
                    bloomSize: bloomSize
                )
                .opacity(presentationOpacity)
                .scaleEffect(state.scale)
                .position(x: xOffset + anchor.x, y: haloY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct LowCostHaloLayerView: View {
    let currentSource: NSImage?
    let incomingSource: NSImage?
    let sourceBlendOpacity: Double
    let bloomSize: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private let internalRenderScale: CGFloat = 0.42
    private var verticalExtent: CGFloat { bloomSize * 1.42 }

    var body: some View {
        let s = max(0.25, min(1.0, internalRenderScale))
        let scaledBloom = bloomSize * s
        let scaledExtent = verticalExtent * s
        let blurRadius = 14.0 * s

        ZStack {
            ZStack {
                if let currentSource {
                    Image(nsImage: currentSource)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                }
                if let incomingSource {
                    Image(nsImage: incomingSource)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .opacity(sourceBlendOpacity)
                }
            }
            .frame(width: scaledBloom, height: scaledExtent)
            .blur(radius: blurRadius, opaque: false)
            .saturation(colorScheme == .dark ? 1.18 : 1.08)
            .brightness(colorScheme == .dark ? 0.01 : 0.05)
            .opacity(colorScheme == .dark ? 0.42 : 0.30)

            Ellipse()
                .fill(colorScheme == .dark ? .regularMaterial : .thickMaterial)
                .frame(width: scaledBloom * 1.00, height: scaledExtent * 0.94)
                .opacity(colorScheme == .dark ? 0.62 : 0.54)

            Ellipse()
                .fill(colorScheme == .dark ? .thinMaterial : .ultraThinMaterial)
                .frame(width: scaledBloom * 0.92, height: scaledExtent * 0.86)
                .opacity(colorScheme == .dark ? 0.40 : 0.32)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12),
                            .clear
                        ],
                        center: UnitPoint(x: 0.5, y: 0.40),
                        startRadius: 0,
                        endRadius: scaledBloom * 0.45
                    )
                )
                .frame(width: scaledBloom, height: scaledExtent)
        }
        .mask(
            EllipticalGradient(
                colors: [
                    .black,
                    .black.opacity(0.74),
                    .black.opacity(0.24),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadiusFraction: 0.05,
                endRadiusFraction: 0.52
            )
        )
        .scaleEffect(1.0 / s)
        .frame(width: bloomSize, height: verticalExtent)
    }
}
