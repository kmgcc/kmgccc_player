//
//  BlurredArtworkBackgroundView.swift
//  myPlayer2
//
//  Large soft blurred artwork image placed at the top of the detail page scroll area.
//  Scrolls with the content — not a fixed window background.
//  Fades out at the bottom via a gradient mask.
//

import SwiftUI

struct BlurredArtworkBackgroundView: View {
    let image: NSImage?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 520)
                .blur(radius: 40, opaque: false)
                .opacity(colorScheme == .dark ? 0.38 : 0.22)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.35),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipped()
                .allowsHitTesting(false)
        }
    }
}
