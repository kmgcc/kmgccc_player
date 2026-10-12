import SwiftUI

extension SemanticPalette {
    /// Processing pressure has a fixed semantic meaning across artwork themes.
    /// Resolve tones for the view's appearance rather than the ambient AppKit
    /// appearance. Surfaces independently control their tint strength.
    func dspProcessingLoadColor(
        _ load: DSPProcessingLoad,
        colorScheme: ColorScheme,
        isChain: Bool = false
    ) -> Color {
        let position = load.colorPosition(isChain: isChain) * 3
        let tones = colorScheme == .dark ? DSPProcessingLoadColors.dark : DSPProcessingLoadColors.light
        if position < 1 { return tones[0].mix(with: tones[1], by: position, in: .device) }
        if position < 2 { return tones[1].mix(with: tones[2], by: position - 1, in: .device) }
        return tones[2].mix(with: tones[3], by: position - 2, in: .device)
    }
}

private enum DSPProcessingLoadColors {
    // Matched perceptual lightness keeps yellow from becoming a bright patch
    // on dark cards. Less chroma in dark mode avoids luminous status surfaces.
    // Render each appearance's four stops once, not on measurement updates.
    static let light = makeTones(lightness: 0.74, chroma: 0.16)
    static let dark = makeTones(lightness: 0.64, chroma: 0.10)

    private static func makeTones(lightness: Double, chroma: Double) -> [Color] {
        [145.0, 95.0, 60.0, 25.0].map { hue in
            ColorRenderingAdapter.makeSwiftUIColor(
                OKLCHColor(lightness: lightness, chroma: chroma, hue: hue / 360)
            )
        }
    }
}
