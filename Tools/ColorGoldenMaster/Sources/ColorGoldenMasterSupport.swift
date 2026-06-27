import AppKit
import Foundation
import SwiftUI

enum GoldenMasterError: Error, CustomStringConvertible {
    case missingArtwork(sampleID: String, path: String)
    case unreadableArtwork(sampleID: String, path: String, message: String)
    case imageDecodeFailed(sampleID: String, source: String)
    case syntheticAnalysisFailed(sampleID: String)
    case unstableOutput
    case missingGolden(path: String)
    case missingExtendedCorpusManifest(path: String)
    case malformedExtendedCorpusManifest(path: String, message: String)
    case extendedArtworkHashChanged(
        sampleID: String,
        path: String,
        expected: UInt64,
        actual: UInt64
    )
    case refreshExtendedCorpusRequiresSeed
    case writeFailed(path: String, message: String)

    var description: String {
        switch self {
        case let .missingArtwork(sampleID, path):
            return "sample artwork path does not exist: sample=\(sampleID) path=\(path)"
        case let .unreadableArtwork(sampleID, path, message):
            return "sample artwork could not be read: sample=\(sampleID) path=\(path) error=\(message)"
        case let .imageDecodeFailed(sampleID, source):
            return "image decode or color analysis failed: sample=\(sampleID) source=\(source)"
        case let .syntheticAnalysisFailed(sampleID):
            return "synthetic sample analysis failed: sample=\(sampleID)"
        case .unstableOutput:
            return "output fields are unstable: two consecutive renders differed"
        case let .missingGolden(path):
            return "golden file missing: \(path)"
        case let .missingExtendedCorpusManifest(path):
            return "extended corpus manifest missing: \(path) (run: Tools/ColorGoldenMaster/run.sh refresh-extended-corpus --seed <seed>)"
        case let .malformedExtendedCorpusManifest(path, message):
            return "extended corpus manifest is malformed: path=\(path) error=\(message)"
        case let .extendedArtworkHashChanged(sampleID, path, expected, actual):
            return "extended corpus artwork hash changed: sample=\(sampleID) path=\(path) expected=\(ColorGoldenMasterSupport.f(expected)) actual=\(ColorGoldenMasterSupport.f(actual))"
        case .refreshExtendedCorpusRequiresSeed:
            return "refresh-extended-corpus requires an explicit seed: Tools/ColorGoldenMaster/run.sh refresh-extended-corpus --seed <seed> [--target 130]"
        case let .writeFailed(path, message):
            return "failed to write output: path=\(path) error=\(message)"
        }
    }
}

struct LoadedGoldenSample {
    let sample: GoldenSample
    let analysis: ArtworkColorAnalysis
    let sourceDescription: String
    let sourceSizeBytes: Int
    let sourceHash: UInt64
    let syntheticPixels: [UInt8]?
}

enum ColorGoldenMasterSupport {
    static let fallbackAccent = NSColor(
        deviceRed: 230.0 / 255.0,
        green: 199.0 / 255.0,
        blue: 153.0 / 255.0,
        alpha: 1.0
    )

    static var bkFallbackPalette: [NSColor] {
        BKExtractedPalettePolicy.fallbackPalette
    }

    static func load(_ sample: GoldenSample) throws -> LoadedGoldenSample {
        switch sample.source {
        case let .realTrack(trackID):
            let path = "\(ColorGoldenMasterSamples.trackRoot)/\(trackID)/artwork.jpg"
            let data = try readArtwork(sampleID: sample.id, path: path)
            guard let analysis = ArtworkColorExtractor.analyze(from: data) else {
                throw GoldenMasterError.imageDecodeFailed(sampleID: sample.id, source: path)
            }
            return LoadedGoldenSample(
                sample: sample,
                analysis: analysis,
                sourceDescription: "track_id=\(trackID) artwork_path=\(path)",
                sourceSizeBytes: data.count,
                sourceHash: ColorMath.fnv1a(data),
                syntheticPixels: nil
            )

        case let .realArtwork(trackID, artworkPath, expectedHash, corpus):
            let data = try readArtwork(sampleID: sample.id, path: artworkPath)
            let actualHash = ColorMath.fnv1a(data)
            guard actualHash == expectedHash else {
                throw GoldenMasterError.extendedArtworkHashChanged(
                    sampleID: sample.id,
                    path: artworkPath,
                    expected: expectedHash,
                    actual: actualHash
                )
            }
            guard let analysis = ArtworkColorExtractor.analyze(from: data) else {
                throw GoldenMasterError.imageDecodeFailed(sampleID: sample.id, source: artworkPath)
            }
            return LoadedGoldenSample(
                sample: sample,
                analysis: analysis,
                sourceDescription: "corpus=\(corpus) track_id=\(trackID) artwork_path=\(artworkPath)",
                sourceSizeBytes: data.count,
                sourceHash: actualHash,
                syntheticPixels: nil
            )

        case let .synthetic(side, regions):
            let pixels = makePixelsMixed(side: side, regions: regions)
            guard let analysis = ArtworkColorExtractor.analyzeSyntheticSample(
                pixels: pixels,
                side: side
            ) else {
                throw GoldenMasterError.syntheticAnalysisFailed(sampleID: sample.id)
            }
            return LoadedGoldenSample(
                sample: sample,
                analysis: analysis,
                sourceDescription: "synthetic side=\(side) regions=\(regionsDescription(regions))",
                sourceSizeBytes: pixels.count,
                sourceHash: ColorMath.fnv1a(Data(pixels)),
                syntheticPixels: pixels
            )
        }
    }

    private static func readArtwork(sampleID: String, path: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else {
            throw GoldenMasterError.missingArtwork(sampleID: sampleID, path: path)
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw GoldenMasterError.unreadableArtwork(
                sampleID: sampleID,
                path: path,
                message: String(describing: error)
            )
        }
    }

    static func makePixelsMixed(side: Int, regions: [SyntheticRegion]) -> [UInt8] {
        let total = side * side
        var out = [UInt8](repeating: 0, count: total * 4)
        var offset = 0
        let lastIndex = regions.count - 1
        for (index, region) in regions.enumerated() {
            let count: Int
            if index == lastIndex {
                count = total - offset
            } else {
                count = Int(Double(total) * region.share)
            }
            let upper = min(offset + count, total)
            for pixelIndex in offset..<upper {
                out[pixelIndex * 4 + 0] = region.rgba.0
                out[pixelIndex * 4 + 1] = region.rgba.1
                out[pixelIndex * 4 + 2] = region.rgba.2
                out[pixelIndex * 4 + 3] = region.rgba.3
            }
            offset += count
        }
        return out
    }

    static func regionsDescription(_ regions: [SyntheticRegion]) -> String {
        regions.map { region in
            "\(f(region.share)):\(region.rgba.0),\(region.rgba.1),\(region.rgba.2),\(region.rgba.3)"
        }.joined(separator: ";")
    }

    static func stableSeed(for sampleID: String, salt: String) -> UInt64 {
        ColorMath.fnv1a(Data("\(sampleID):\(salt)".utf8))
    }

    static func nsColor(from color: Color) -> NSColor {
        NSColor(color)
    }

    static func nsColor(from cgColor: CGColor) -> NSColor? {
        NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB)
    }

    static func ledOpacity(for level: Int, maxLevel: Int, scheme: ColorScheme) -> CGFloat {
        guard level > 0, maxLevel > 0 else { return 0 }
        let t = CGFloat(level) / CGFloat(maxLevel)
        if scheme == .dark {
            return 0.08 + pow(t, 1.55) * 0.92
        } else {
            return 0.06 + pow(t, 1.65) * 0.94
        }
    }

    static func f(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func f(_ value: CGFloat) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    static func f(_ value: UInt64) -> String {
        String(format: "0x%016llX", value)
    }

    static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    static func range(_ value: ClosedRange<CGFloat>) -> String {
        "\(f(value.lowerBound))...\(f(value.upperBound))"
    }

    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = UInt8((min(max(rgb.redComponent, 0), 1) * 255).rounded())
        let g = UInt8((min(max(rgb.greenComponent, 0), 1) * 255).rounded())
        let b = UInt8((min(max(rgb.blueComponent, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func colorDescription(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let lch = OKColor.nsColorToOKLCH(rgb)
        let lchText = lch.map(lchDescription(_:)) ?? "oklch=nil"
        let hueReliable = lch.map { $0.c >= ColorSystemTokens.NearMonochromeProfile.mutedTrustedHueChromaFloor } ?? false
        return "\(hex(rgb)) a=\(f(rgb.alphaComponent)) \(lchText) hue_reliable=\(bool(hueReliable))"
    }

    static func lchDescription(_ lch: OKColor.OKLCH?) -> String {
        guard let lch else { return "oklch=nil" }
        return lchDescription(lch)
    }

    static func lchDescription(_ lch: OKColor.OKLCH) -> String {
        "oklch(L=\(f(lch.l)) C=\(f(lch.c)) H=\(f(lch.h)))"
    }
}
