//
//  ScrollEdgeFadeMask.swift
//  myPlayer2
//
//  Shared alpha mask for scrollable surfaces that should feather content at
//  their clipped edges without changing layout.
//

import SwiftUI

struct ScrollEdgeFadeState: Equatable {
    var topOpacity: Double = 0
    var bottomOpacity: Double = 0

    init() {}

    init(
        geometry: ScrollGeometry,
        fadeHeight: CGFloat
    ) {
        self.init(
            geometry: geometry,
            topFadeDistance: fadeHeight,
            bottomFadeDistance: fadeHeight
        )
    }

    init(
        geometry: ScrollGeometry,
        topFadeDistance: CGFloat,
        bottomFadeDistance: CGFloat
    ) {
        let epsilon: CGFloat = 0.5
        let topOffset = -geometry.contentInsets.top
        let bottomOffset = max(
            topOffset,
            geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
        )
        let scrollableDistance = bottomOffset - topOffset

        guard scrollableDistance > epsilon else { return }

        let distanceFromTop = max(0, geometry.contentOffset.y - topOffset)
        let distanceToBottom = max(0, bottomOffset - geometry.contentOffset.y)

        topOpacity = Self.opacity(for: distanceFromTop, fadeDistance: topFadeDistance, epsilon: epsilon)
        bottomOpacity = Self.opacity(for: distanceToBottom, fadeDistance: bottomFadeDistance, epsilon: epsilon)
    }

    private static func opacity(
        for distance: CGFloat,
        fadeDistance: CGFloat,
        epsilon: CGFloat
    ) -> Double {
        guard fadeDistance > epsilon else { return 0 }

        let progress = min(max((distance - epsilon) / fadeDistance, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return Double(easedProgress)
    }
}

extension View {
    func scrollEdgeFadeMask(
        _ state: ScrollEdgeFadeState,
        fadeHeight: CGFloat,
        topEnabled: Bool = true,
        bottomEnabled: Bool = true,
        animation: Animation = .easeInOut(duration: 0.2)
    ) -> some View {
        scrollEdgeFadeMask(
            state,
            topFadeHeight: fadeHeight,
            bottomFadeHeight: fadeHeight,
            topEnabled: topEnabled,
            bottomEnabled: bottomEnabled,
            animation: animation
        )
    }

    func scrollEdgeFadeMask(
        _ state: ScrollEdgeFadeState,
        topFadeHeight: CGFloat,
        bottomFadeHeight: CGFloat,
        topChromeInset: CGFloat = 0,
        topEnabled: Bool = true,
        bottomEnabled: Bool = true,
        animation: Animation = .easeInOut(duration: 0.2)
    ) -> some View {
        mask {
            ScrollEdgeFadeMask(
                topOpacity: topEnabled ? state.topOpacity : 0,
                bottomOpacity: bottomEnabled ? state.bottomOpacity : 0,
                topFadeHeight: topFadeHeight,
                bottomFadeHeight: bottomFadeHeight,
                topChromeInset: topChromeInset
            )
            .animation(animation, value: state.topOpacity)
            .animation(animation, value: state.bottomOpacity)
        }
    }
}

struct ScrollEdgeFadeMask: View {
    let topOpacity: Double
    let bottomOpacity: Double
    let topFadeHeight: CGFloat
    let bottomFadeHeight: CGFloat
    var topChromeInset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let maxFadeHeight = max(0, proxy.size.height / 2)
            let resolvedTopHeight = min(max(topFadeHeight, topChromeInset), maxFadeHeight)
            let resolvedBottomHeight = min(bottomFadeHeight, maxFadeHeight)
            let topAlpha = min(max(topOpacity, 0), 1)
            let bottomAlpha = min(max(bottomOpacity, 0), 1)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        .black.opacity(1 - topAlpha),
                        .black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: resolvedTopHeight)

                Color.black

                LinearGradient(
                    colors: [
                        .black,
                        .black.opacity(1 - bottomAlpha)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: resolvedBottomHeight)
            }
        }
    }
}
