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
}

enum ColorGoldenMasterReadabilityParity {
    static func buildRows() throws -> [ReadabilityParityRow] {
        let sections = try ColorGoldenMasterSamples.sections()
        var rows: [ReadabilityParityRow] = []
        for section in sections {
            for sample in section.samples {
                let loaded = try ColorGoldenMasterSupport.load(sample)
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
                        readabilityDecision: readableDecision
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
                        readabilityDecision: readableDecision
                    ))
                }
            }
        }
        return rows
    }
    
    static func render() throws -> String {
        let rows = try buildRows()
        var lines: [String] = []
        lines.append("# Text Readability OKLCH Parity Report")
        lines.append("sample\trole\tscheme\tuses_dark_fg\tis_near_mono\tlegacy_hex\tcandidate_hex\tdelta_l\tdelta_c\tdelta_h\tdelta_e_oklab\tdecision\tclassification")
        for r in rows {
            lines.append("\(r.sample)\t\(r.role)\t\(r.scheme)\t\(r.usesDarkForeground)\t\(r.isNearMonochrome)\t\(r.legacyHex)\t\(r.candidateHex)\t\(r.deltaL)\t\(r.deltaC)\t\(r.deltaH)\t\(r.deltaEOKLab)\t\(r.readabilityDecision)\t\(r.classification)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
