//
//  BlurredArtworkBackgroundView.swift
//  myPlayer2
//
//  Soft blurred artwork glow positioned under the detail header artwork.
//  Fixed visual size — not a full-width wash.
//  The image is scaled, heavily blurred, and faded radially to create
//  a localized halo effect that reads as "the cover enlarged and blurred beneath itself."
//

import SwiftUI

struct BlurredArtworkBackgroundView: View {
    let image: NSImage?
    var bloomSize: CGFloat = 1000

    @Environment(\.colorScheme) private var colorScheme

    /// Vertical stretch factor — the halo extends further below center
    /// so it remains visible after the cover scrolls out of view.
    private var verticalExtent: CGFloat { bloomSize * 1.5 }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: bloomSize, height: verticalExtent)
                .blur(radius: bloomSize * 0.085, opaque: false)
                // Boost saturation for richer color bloom
                .saturation(1.35)
                // Lower opacity for softer glow
                .opacity(colorScheme == .dark ? 0.38 : 0.28)
                // In light mode, slightly boost brightness for better visibility
                .brightness(colorScheme == .dark ? 0.0 : 0.08)
                .mask(
                    EllipticalGradient(
                        colors: [
                            .black,
                            .black.opacity(0.7),
                            .black.opacity(0.2),
                            .clear
                        ],
                        center: UnitPoint(x: 0.5, y: 0.38),
                        startRadiusFraction: 0.04,
                        endRadiusFraction: 0.5
                    )
                )
                .allowsHitTesting(false)
        }
    }
}
