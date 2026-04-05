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

    @Environment(\.colorScheme) private var colorScheme

    // Bloom is a fixed visual footprint, independent of window width.
    private let bloomSize: CGFloat = 500

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: bloomSize, height: bloomSize)
                .blur(radius: 80, opaque: false)
                .opacity(colorScheme == .dark ? 0.52 : 0.32)
                .mask(
                    RadialGradient(
                        colors: [
                            .black,
                            .black.opacity(0.7),
                            .black.opacity(0.2),
                            .clear
                        ],
                        center: .center,
                        startRadius: 60,
                        endRadius: bloomSize / 2
                    )
                )
                .allowsHitTesting(false)
        }
    }
}
