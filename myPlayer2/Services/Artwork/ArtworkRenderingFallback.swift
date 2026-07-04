//
//  ArtworkRenderingFallback.swift
//  myPlayer2
//
//  In-memory artwork fallback used only by rendering/color pipelines.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArtworkRenderingFallback {
    nonisolated static let identity = "rendering-fallback:XCAssets/artworkFallback1|XCAssets/artworkFallback2"
    nonisolated static let defaultTrackID = UUID(uuidString: "7E9E8E9D-1B19-4D9B-B89C-1041F87D55E8")!
    private nonisolated static let maxPixel = 1_600
    private nonisolated static let assets: [FallbackAsset] = [
        FallbackAsset(logicalName: "XCAssets/artworkFallback1"),
        FallbackAsset(logicalName: "XCAssets/artworkFallback2"),
    ]

    nonisolated static var data: Data? {
        data(for: nil)
    }

    nonisolated static var checksum: UInt64 {
        checksum(for: nil)
    }

    nonisolated static func data(for preferredTrackID: UUID?) -> Data? {
        Cached.data(logicalName: selectedAsset(for: preferredTrackID).logicalName)
    }

    nonisolated static func checksum(for preferredTrackID: UUID?) -> UInt64 {
        ArtworkAssetStore.checksum(for: data(for: preferredTrackID))
    }

    nonisolated static func identity(for preferredTrackID: UUID?) -> String {
        "rendering-fallback:\(selectedAsset(for: preferredTrackID).logicalName)"
    }

    nonisolated static func shouldUse(for artworkData: Data?, isArtworkLoading: Bool) -> Bool {
        artworkData?.isEmpty != false && !isArtworkLoading
    }

    nonisolated static func resolvedTrackID(_ preferredTrackID: UUID?) -> UUID {
        preferredTrackID ?? defaultTrackID
    }

    private nonisolated static func selectedAsset(for preferredTrackID: UUID?) -> FallbackAsset {
        let trackID = resolvedTrackID(preferredTrackID)
        let index = Int(stableIndexSeed(for: trackID) % UInt64(assets.count))
        return assets[index]
    }

    private nonisolated static func stableIndexSeed(for trackID: UUID) -> UInt64 {
        withUnsafeBytes(of: trackID.uuid) { bytes in
            bytes.reduce(UInt64(0xcbf29ce484222325)) { hash, byte in
                (hash ^ UInt64(byte)) &* UInt64(0x100000001b3)
            }
        }
    }

    private struct FallbackAsset: Sendable {
        let logicalName: String
    }

    private enum Cached {
        nonisolated static let artworkFallback1: Data? = makePNGData(logicalName: "XCAssets/artworkFallback1")
        nonisolated static let artworkFallback2: Data? = makePNGData(logicalName: "XCAssets/artworkFallback2")

        nonisolated static func data(logicalName: String) -> Data? {
            switch logicalName {
            case "XCAssets/artworkFallback1":
                return artworkFallback1
            case "XCAssets/artworkFallback2":
                return artworkFallback2
            default:
                return nil
            }
        }
    }

    private nonisolated static func makePNGData(logicalName: String) -> Data? {
        guard
            let image = EncryptedArtAssetLoader.shared.cgImage(
                logicalName: logicalName,
                in: nil,
                maxPixel: maxPixel
            )
        else {
            return nil
        }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
