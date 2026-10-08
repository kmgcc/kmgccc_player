import SwiftUI

struct FullscreenHorizontalSplitLayout {
    let artworkWidth: CGFloat
    let lyricsWidth: CGFloat
    let safeGap: CGFloat
    let artworkLeadingX: CGFloat
    let lyricsLeadingX: CGFloat

    private static let baseCanvasWidth: CGFloat = 1470
    private static let sideInset: CGFloat = 24
    private static let rightReserve: CGFloat = 88
    private static let artworkIdealRatio: CGFloat = 0.54
    private static let artworkMinWidth: CGFloat = 360
    private static let artworkIdealMinWidth: CGFloat = 540
    private static let artworkMaxRatio: CGFloat = 0.65
    private static let lyricsIdealRatio: CGFloat = 0.34
    private static let lyricsIdealMinWidth: CGFloat = 420
    private static let lyricsMinReadableWidth: CGFloat = 340
    private static let lyricsMaxRatio: CGFloat = 0.52
    private static let safeGapRatio: CGFloat = 0.024
    private static let safeGapMin: CGFloat = 12
    private static let safeGapFloor: CGFloat = 4
    private static let artworkVisualTrimWhenLyricsVisible: CGFloat = 32

    static func resolve(
        showLyricsColumn: Bool,
        windowWidth: CGFloat? = nil
    ) -> FullscreenHorizontalSplitLayout {
        let canvasWidth = max(0, windowWidth ?? baseCanvasWidth)
        let availableWidth = max(0, canvasWidth - sideInset * 2 - rightReserve)

        if !showLyricsColumn {
            let centeredAvailableWidth = max(0, canvasWidth - sideInset * 2)
            let artworkWidth = min(
                max(centeredAvailableWidth * 0.78, lyricsIdealMinWidth),
                centeredAvailableWidth
            )
            let artworkLeadingX = sideInset + max(0, (centeredAvailableWidth - artworkWidth) * 0.5)
            return FullscreenHorizontalSplitLayout(
                artworkWidth: artworkWidth,
                lyricsWidth: 0,
                safeGap: 0,
                artworkLeadingX: artworkLeadingX,
                lyricsLeadingX: artworkLeadingX + artworkWidth
            )
        }

        let maxArtworkWidth = max(artworkMinWidth, availableWidth * artworkMaxRatio)
        let maxLyricsWidth = max(
            lyricsMinReadableWidth,
            availableWidth * lyricsMaxRatio
        )
        var artworkWidth = min(
            max(availableWidth * artworkIdealRatio, artworkIdealMinWidth),
            maxArtworkWidth
        )
        var lyricsWidth = min(
            max(availableWidth * lyricsIdealRatio, lyricsIdealMinWidth),
            maxLyricsWidth
        )
        var safeGap = max(safeGapMin, availableWidth * safeGapRatio)

        var overflow = artworkWidth + safeGap + lyricsWidth - availableWidth
        if overflow > 0 {
            let gapShrink = min(overflow, safeGap - safeGapFloor)
            safeGap -= gapShrink
            overflow -= gapShrink
        }
        if overflow > 0 {
            let artworkShrink = min(overflow, artworkWidth - artworkMinWidth)
            artworkWidth -= artworkShrink
            overflow -= artworkShrink
        }
        if overflow > 0 {
            let lyricsShrink = min(overflow, lyricsWidth - lyricsMinReadableWidth)
            lyricsWidth -= lyricsShrink
            overflow -= lyricsShrink
        }
        if overflow > 0 {
            artworkWidth = max(artworkMinWidth, artworkWidth - overflow)
        }

        var remaining = availableWidth - (artworkWidth + safeGap + lyricsWidth)
        if remaining > 0 {
            let artworkGrowth = min(remaining * 0.40, maxArtworkWidth - artworkWidth)
            artworkWidth += artworkGrowth
            remaining -= artworkGrowth
        }
        if remaining > 0 {
            let lyricsGrowth = min(remaining * 0.60, maxLyricsWidth - lyricsWidth)
            lyricsWidth += lyricsGrowth
            remaining -= lyricsGrowth
        }

        let effectiveArtworkZoneWidth = max(
            artworkMinWidth,
            artworkWidth - artworkVisualTrimWhenLyricsVisible
        )
        let groupWidth = effectiveArtworkZoneWidth + safeGap + lyricsWidth
        let outerSlack = max(0, availableWidth - groupWidth)
        let wideWindowLeftBias = outerSlack > 1 ? min(196, 36 + outerSlack * 0.60) : 0
        let artworkLeadingX = max(
            0,
            sideInset + outerSlack * 0.5 - wideWindowLeftBias
        )
        let lyricsLeadingX = artworkLeadingX + effectiveArtworkZoneWidth + safeGap

        return FullscreenHorizontalSplitLayout(
            artworkWidth: artworkWidth,
            lyricsWidth: lyricsWidth,
            safeGap: safeGap,
            artworkLeadingX: artworkLeadingX,
            lyricsLeadingX: lyricsLeadingX
        )
    }
}
