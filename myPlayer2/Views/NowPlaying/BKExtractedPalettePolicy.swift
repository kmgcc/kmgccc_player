import AppKit
import Foundation

nonisolated enum BKExtractedPalettePolicy {
    static var fallbackPalette: [NSColor] {
        [
            NSColor(calibratedRed: 0.50, green: 0.62, blue: 0.76, alpha: 1.0),
            NSColor(calibratedRed: 0.76, green: 0.54, blue: 0.52, alpha: 1.0),
            NSColor(calibratedRed: 0.56, green: 0.72, blue: 0.46, alpha: 1.0),
        ]
    }

    static func select(
        analysis: ArtworkColorAnalysis?,
        basePalette: [NSColor],
        richPalette: [NSColor],
        fallbackPalette: [NSColor] = Self.fallbackPalette
    ) -> [NSColor] {
        if let analysis {
            var selected: [NSColor] = []

            func rgbDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
                let l = lhs.usingColorSpace(.deviceRGB) ?? lhs
                let r = rhs.usingColorSpace(.deviceRGB) ?? rhs
                let dr = l.redComponent - r.redComponent
                let dg = l.greenComponent - r.greenComponent
                let db = l.blueComponent - r.blueComponent
                return sqrt(dr * dr + dg * dg + db * db)
            }

            func appendDistinct(_ color: NSColor) {
                let ready = color.usingColorSpace(.deviceRGB) ?? color
                guard selected.allSatisfy({ rgbDistance($0, ready) >= 0.050 }) else { return }
                selected.append(ready)
            }

            func isVisibleSurfaceMaterial(_ color: NSColor) -> Bool {
                guard let rgb = color.usingColorSpace(.deviceRGB),
                      let lch = OKColor.nsColorToOKLCH(rgb)
                else { return false }
                return lch.c >= 0.008
                    && lch.l >= 0.08
                    && lch.l <= 0.97
            }

            func isUsefulBackgroundMaterial(_ color: NSColor, areaShare: CGFloat?) -> Bool {
                guard let rgb = color.usingColorSpace(.deviceRGB),
                      let lch = OKColor.nsColorToOKLCH(rgb)
                else { return false }

                let share = areaShare ?? 0
                let dominantTonalField = share >= 0.18
                    && (lch.l <= 0.22 || (lch.l >= 0.78 && lch.c <= 0.025))
                let visibleMaterial = lch.c >= 0.006
                    && lch.l >= 0.08
                    && lch.l <= 0.97
                let mutedAreaColor = share >= 0.012
                    && lch.c >= 0.010
                    && lch.l >= 0.05
                    && lch.l <= 0.98
                return dominantTonalField || visibleMaterial || mutedAreaColor
            }

            func appendBackgroundMaterial(_ color: NSColor, areaShare: CGFloat? = nil) {
                guard isUsefulBackgroundMaterial(color, areaShare: areaShare) else { return }
                appendDistinct(color)
            }

            func isSmallSalientVariant(_ color: NSColor) -> Bool {
                guard let rgb = color.usingColorSpace(.deviceRGB),
                      let lch = OKColor.nsColorToOKLCH(rgb)
                else { return false }

                for (index, salient) in analysis.salientHighlightPalette.enumerated() {
                    let share = index < analysis.salientHighlightAreaShares.count
                        ? analysis.salientHighlightAreaShares[index]
                        : 1
                    guard share <= 0.080,
                          let salientRGB = salient.usingColorSpace(.deviceRGB),
                          let salientLCH = OKColor.nsColorToOKLCH(salientRGB)
                    else { continue }
                    if rgbDistance(rgb, salientRGB) < 0.12 {
                        return true
                    }
                    if lch.c >= 0.024,
                       ColorMath.circularHueDistance(lch.h, salientLCH.h) <= 0.055 {
                        return true
                    }
                }
                return false
            }

            if analysis.hasTrustedHueCandidate {
                for (index, color) in analysis.surfacePalette.enumerated() {
                    let share = index < analysis.surfacePaletteAreaShares.count
                        ? analysis.surfacePaletteAreaShares[index]
                        : nil
                    appendBackgroundMaterial(color, areaShare: share)
                }
                for color in analysis.topPalette where isVisibleSurfaceMaterial(color) {
                    guard !isSmallSalientVariant(color) else { continue }
                    appendBackgroundMaterial(color)
                }
                for color in analysis.displayPalette where !isSmallSalientVariant(color) {
                    appendBackgroundMaterial(color)
                }

                if selected.count == 1,
                   let only = selected.first,
                   let onlyLCH = OKColor.nsColorToOKLCH(only) {
                    if onlyLCH.l < 0.08, !analysis.salientHighlightPalette.isEmpty {
                        appendDistinct(analysis.averageColor)
                    }
                }
            } else {
                for color in analysis.displayPalette { appendDistinct(color) }
            }
            if !selected.isEmpty {
                return Array(selected.prefix(8))
            }
        }
        if !richPalette.isEmpty {
            return richPalette
        }
        if !basePalette.isEmpty {
            return basePalette
        }
        return fallbackPalette
    }
}
