import AppKit
import Foundation
import SwiftUI

struct ReadabilityParityRow {
    let sample: String
    let sectionID: String
    let role: String // "readableText" or "coverGradientText"
    let scheme: String // "dark" or "light"
    let usesDarkForeground: Bool
    let isNearMonochrome: Bool
    let legacyHex: String
    let candidateHex: String
    let legacyOKLCH: String
    let candidateOKLCH: String
    let deltaL: String
    let deltaC: String
    let deltaH: String
    let deltaEOKLab: String
    let classification: String // "unchanged", "drift"
    let readabilityDecision: String // e.g. "dark_on_light" or "light_on_dark"

    // Polarity flip audit (Phase 7 strict global gate). `current` is the old
    // single `avgHslL >= 0.58` threshold; `proposed` is the new strict policy
    // (== `analysis.usesDarkForeground`). The flip column classifies each
    // sample so the dark->light recall list stays auditable.
    let currentPolarity: String
    let proposedPolarity: String
    let avgHslLightness: String
    let weightedLuma: String
    let avgBrightness: String
    let avgSaturation: String
    let brightAreaRatio: String
    let darkAreaRatio: String
    let flipClassification: String // unchanged_light | unchanged_dark | dark_to_light | light_to_dark
    let gateReason: String
}

enum ColorGoldenMasterReadabilityParity {
    static func buildRows() throws -> [ReadabilityParityRow] {
        let sections = try ColorGoldenMasterSamples.sections()
        var rows: [ReadabilityParityRow] = []
        for section in sections {
            for sample in section.samples {
                // Tolerate unavailable real-artwork samples (deleted tracks /
                // hash drift) so the parity report can still run on the
                // available corpus. Strict drift detection stays the job of
                // `verify`; here we only skip + warn.
                let loaded: LoadedGoldenSample
                do {
                    loaded = try ColorGoldenMasterSupport.load(sample)
                } catch {
                    FileHandle.standardError.write(
                        Data("readability-parity: skipping unavailable sample \(sample.id): \(error)\n".utf8)
                    )
                    continue
                }
                let analysis = loaded.analysis

                for scheme in [ColorScheme.dark, ColorScheme.light] {
                    let usesDarkForeground = analysis.usesDarkForeground

                    // Readable Text
                    let legacyReadable = SemanticPaletteSelfCheck.legacyReadableTextOnArtwork(analysis)
                    let candidateReadable = SemanticPaletteSelfCheck.readableTextOnArtworkOKLCH(analysis)
                    let diffReadable = ColorDifference(legacy: legacyReadable, candidate: candidateReadable)

                    let readableDecision = usesDarkForeground ? "dark_on_light" : "light_on_dark"
                    let readabilityClassification = diffReadable.isUnchanged ? "unchanged" : "drift"

                    rows.append(ReadabilityParityRow(
                        sample: sample.id,
                        sectionID: section.id,
                        role: "readableText",
                        scheme: scheme == .dark ? "dark" : "light",
                        usesDarkForeground: usesDarkForeground,
                        isNearMonochrome: analysis.isNearMonochrome,
                        legacyHex: ColorGoldenMasterSupport.hex(legacyReadable),
                        candidateHex: ColorGoldenMasterSupport.hex(candidateReadable),
                        legacyOKLCH: ColorGoldenMasterSupport.colorDescription(legacyReadable),
                        candidateOKLCH: ColorGoldenMasterSupport.colorDescription(candidateReadable),
                        deltaL: ColorGoldenMasterSupport.f(diffReadable.deltaL),
                        deltaC: ColorGoldenMasterSupport.f(diffReadable.deltaC),
                        deltaH: ColorGoldenMasterSupport.f(diffReadable.deltaH),
                        deltaEOKLab: ColorGoldenMasterSupport.f(diffReadable.deltaEOKLab),
                        classification: readabilityClassification,
                        readabilityDecision: readableDecision,
                        currentPolarity: polarityLabel(legacyUsesDark: legacyUsesDarkForeground(analysis)),
                        proposedPolarity: polarityLabel(legacyUsesDark: usesDarkForeground),
                        avgHslLightness: ColorGoldenMasterSupport.f(analysis.avgHslLightness),
                        weightedLuma: ColorGoldenMasterSupport.f(analysis.weightedLuma),
                        avgBrightness: ColorGoldenMasterSupport.f(analysis.avgBrightness),
                        avgSaturation: ColorGoldenMasterSupport.f(analysis.avgSaturation),
                        brightAreaRatio: ColorGoldenMasterSupport.f(analysis.brightAreaRatio),
                        darkAreaRatio: ColorGoldenMasterSupport.f(analysis.darkAreaRatio),
                        flipClassification: flipClassification(
                            legacyUsesDark: legacyUsesDarkForeground(analysis),
                            proposedUsesDark: usesDarkForeground
                        ),
                        gateReason: ArtworkForegroundPolarityPolicy.globalGateReason(
                            avgHslLightness: analysis.avgHslLightness,
                            weightedLuma: analysis.weightedLuma,
                            avgBrightness: analysis.avgBrightness,
                            avgSaturation: analysis.avgSaturation
                        ).rawValue
                    ))

                    // Cover Gradient Text
                    let legacyCGText = SemanticPaletteSelfCheck.legacyCoverGradientText(analysis)
                    let candidateCGText = SemanticPaletteSelfCheck.coverGradientTextOKLCH(analysis)
                    let diffCGText = ColorDifference(legacy: legacyCGText, candidate: candidateCGText)

                    let cgClassification = diffCGText.isUnchanged ? "unchanged" : "drift"

                    rows.append(ReadabilityParityRow(
                        sample: sample.id,
                        sectionID: section.id,
                        role: "coverGradientText",
                        scheme: scheme == .dark ? "dark" : "light",
                        usesDarkForeground: usesDarkForeground,
                        isNearMonochrome: analysis.isNearMonochrome,
                        legacyHex: ColorGoldenMasterSupport.hex(legacyCGText),
                        candidateHex: ColorGoldenMasterSupport.hex(candidateCGText),
                        legacyOKLCH: ColorGoldenMasterSupport.colorDescription(legacyCGText),
                        candidateOKLCH: ColorGoldenMasterSupport.colorDescription(candidateCGText),
                        deltaL: ColorGoldenMasterSupport.f(diffCGText.deltaL),
                        deltaC: ColorGoldenMasterSupport.f(diffCGText.deltaC),
                        deltaH: ColorGoldenMasterSupport.f(diffCGText.deltaH),
                        deltaEOKLab: ColorGoldenMasterSupport.f(diffCGText.deltaEOKLab),
                        classification: cgClassification,
                        readabilityDecision: readableDecision,
                        currentPolarity: polarityLabel(legacyUsesDark: legacyUsesDarkForeground(analysis)),
                        proposedPolarity: polarityLabel(legacyUsesDark: usesDarkForeground),
                        avgHslLightness: ColorGoldenMasterSupport.f(analysis.avgHslLightness),
                        weightedLuma: ColorGoldenMasterSupport.f(analysis.weightedLuma),
                        avgBrightness: ColorGoldenMasterSupport.f(analysis.avgBrightness),
                        avgSaturation: ColorGoldenMasterSupport.f(analysis.avgSaturation),
                        brightAreaRatio: ColorGoldenMasterSupport.f(analysis.brightAreaRatio),
                        darkAreaRatio: ColorGoldenMasterSupport.f(analysis.darkAreaRatio),
                        flipClassification: flipClassification(
                            legacyUsesDark: legacyUsesDarkForeground(analysis),
                            proposedUsesDark: usesDarkForeground
                        ),
                        gateReason: ArtworkForegroundPolarityPolicy.globalGateReason(
                            avgHslLightness: analysis.avgHslLightness,
                            weightedLuma: analysis.weightedLuma,
                            avgBrightness: analysis.avgBrightness,
                            avgSaturation: analysis.avgSaturation
                        ).rawValue
                    ))
                }
            }
        }
        return rows
    }

    /// The pre-Phase-7 single-threshold polarity (`avgHslL >= 0.58`). Kept as
    /// the "current" reference so the report can show the dark->light recall.
    private static func legacyUsesDarkForeground(_ analysis: ArtworkColorAnalysis) -> Bool {
        analysis.avgHslLightness >= ColorSystemTokens.ReadabilityForeground.usesDarkAvgHslL
    }

    private static func polarityLabel(legacyUsesDark: Bool) -> String {
        legacyUsesDark ? "dark_on_light" : "light_on_dark"
    }

    private static func flipClassification(legacyUsesDark: Bool, proposedUsesDark: Bool) -> String {
        switch (legacyUsesDark, proposedUsesDark) {
        case (false, false): return "unchanged_light"
        case (true, true): return "unchanged_dark"
        case (true, false): return "dark_to_light"
        case (false, true): return "light_to_dark"
        }
    }

    static func render() throws -> String {
        let rows = try buildRows()
        var lines: [String] = []
        lines.append("# Text Readability OKLCH Parity Report")
        lines.append("sample\trole\tscheme\tuses_dark_fg\tis_near_mono\tlegacy_hex\tcandidate_hex\tdelta_l\tdelta_c\tdelta_h\tdelta_e_oklab\tdecision\tclassification\tcurrent_polarity\tproposed_polarity\tavg_hsl_lightness\tweighted_luma\tavg_brightness\tavg_saturation\tbright_area_ratio\tdark_area_ratio\tflip\tgate_reason")
        for r in rows {
            lines.append("\(r.sample)\t\(r.role)\t\(r.scheme)\t\(r.usesDarkForeground)\t\(r.isNearMonochrome)\t\(r.legacyHex)\t\(r.candidateHex)\t\(r.deltaL)\t\(r.deltaC)\t\(r.deltaH)\t\(r.deltaEOKLab)\t\(r.readabilityDecision)\t\(r.classification)\t\(r.currentPolarity)\t\(r.proposedPolarity)\t\(r.avgHslLightness)\t\(r.weightedLuma)\t\(r.avgBrightness)\t\(r.avgSaturation)\t\(r.brightAreaRatio)\t\(r.darkAreaRatio)\t\(r.flipClassification)\t\(r.gateReason)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
