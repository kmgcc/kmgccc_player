//
//  ArtworkAssetStore.swift
//  myPlayer2
//
//  kmgccc_player - Thread-safe artwork asset caching store
//

import AppKit
import Foundation
import ImageIO

actor ArtworkAssetStore {
    static let shared = ArtworkAssetStore()

    private let cache: NSCache<NSString, ArtworkAssetSnapshot> = {
        let cache = NSCache<NSString, ArtworkAssetSnapshot>()
        cache.countLimit = 96
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private let fullImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var inProgressKeys: Set<String> = []
    private var waitingContinuations: [String: [CheckedContinuation<ArtworkAssetSnapshot?, Never>]] = [:]
    private var fullImageInProgressKeys: Set<String> = []
    private var fullImageWaitingContinuations: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private var fullImageGeneration: UInt64 = 0
    
    func clearCache() {
        cache.removeAllObjects()
        fullImageCache.removeAllObjects()
        inProgressKeys.removeAll()
        waitingContinuations.removeAll()
        fullImageInProgressKeys.removeAll()
        fullImageGeneration &+= 1
        for waiters in fullImageWaitingContinuations.values {
            for continuation in waiters {
                continuation.resume(returning: nil)
            }
        }
        fullImageWaitingContinuations.removeAll()
    }

    func purgeHydratedImages() {
        fullImageGeneration &+= 1
        fullImageCache.removeAllObjects()
        fullImageInProgressKeys.removeAll()
        for waiters in fullImageWaitingContinuations.values {
            for continuation in waiters {
                continuation.resume(returning: nil)
            }
        }
        fullImageWaitingContinuations.removeAll()
    }

    func clearTrackDeletionResidue() {
        purgeHydratedImages()
    }
    
    nonisolated static func checksum(for data: Data?) -> UInt64 {
        guard let data, !data.isEmpty else { return 0 }
        return computeChecksum(data)
    }
    
    func get(trackID: UUID, artworkChecksum: UInt64) -> ArtworkAssetSnapshot? {
        let key = "\(trackID.uuidString)-\(artworkChecksum)"
        return cache.object(forKey: key as NSString)
    }
    
    func snapshot(
        trackID: UUID,
        artworkData: Data,
        fullImageMaxPixelSize: Int = 1_400
    ) async -> ArtworkAssetSnapshot? {
        let checksum = Self.computeChecksum(artworkData)
        let snapshot = await snapshotMetadata(
            trackID: trackID,
            artworkData: artworkData,
            artworkChecksum: checksum
        )

        return await hydrateSnapshot(
            snapshot,
            artworkData: artworkData,
            fullImageMaxPixelSize: fullImageMaxPixelSize
        )
    }

    func snapshotMetadata(trackID: UUID, artworkData: Data) async -> ArtworkAssetSnapshot? {
        let checksum = Self.computeChecksum(artworkData)
        return await snapshotMetadata(
            trackID: trackID,
            artworkData: artworkData,
            artworkChecksum: checksum
        )
    }
    
    func cache(_ snapshot: ArtworkAssetSnapshot) {
        let metadataSnapshot = snapshot.replacing(fullImage: nil)
        let thumbnailCost = metadataSnapshot.thumbnailImage.flatMap(Self.estimatedCost(for:)) ?? 0
        let paletteCost = (snapshot.palette.count + snapshot.richPalette.count) * 64
        let cost = thumbnailCost + paletteCost
        cache.setObject(metadataSnapshot, forKey: metadataSnapshot.cacheKey as NSString, cost: cost)

        if let fullImage = snapshot.fullImage {
            fullImageCache.setObject(
                fullImage,
                forKey: snapshot.cacheKey as NSString,
                cost: Self.estimatedCost(for: fullImage)
            )
        }
    }
    
    func getOrCreate(
        trackID: UUID,
        artworkData: Data,
        artworkChecksum: UInt64,
        extract: @Sendable @escaping (Data, UInt64) async -> ArtworkAssetSnapshot?
    ) async -> ArtworkAssetSnapshot? {
        let key = "\(trackID.uuidString)-\(artworkChecksum)"
        
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        
        if inProgressKeys.contains(key) {
            return await withCheckedContinuation { continuation in
                waitingContinuations[key, default: []].append(continuation)
            }
        }
        
        inProgressKeys.insert(key)
        let result = await extract(artworkData, artworkChecksum)
        
        if let snapshot = result {
            cache(snapshot)
        }
        
        inProgressKeys.remove(key)
        
        if let waiters = waitingContinuations.removeValue(forKey: key) {
            for continuation in waiters {
                continuation.resume(returning: result)
            }
        }
        
        return result
    }

    private func hydrateSnapshot(
        _ snapshot: ArtworkAssetSnapshot?,
        artworkData: Data,
        fullImageMaxPixelSize: Int
    ) async -> ArtworkAssetSnapshot? {
        guard let snapshot else { return nil }
        if snapshot.fullImage != nil { return snapshot }

        let hydratedKey = "\(snapshot.cacheKey)|full:\(max(1, fullImageMaxPixelSize))"
        let key = hydratedKey as NSString
        if let cachedFullImage = fullImageCache.object(forKey: key) {
            return snapshot.replacing(fullImage: cachedFullImage)
        }

        if fullImageInProgressKeys.contains(hydratedKey) {
            let image = await withCheckedContinuation { continuation in
                fullImageWaitingContinuations[hydratedKey, default: []].append(continuation)
            }
            return snapshot.replacing(fullImage: image)
        }

        fullImageInProgressKeys.insert(hydratedKey)
        let generation = fullImageGeneration
        let fullImage = await Task.detached(priority: .utility) {
            Self.downsampledImage(
                data: artworkData,
                maxPixelSize: max(1, fullImageMaxPixelSize)
            )
        }.value

        if generation == fullImageGeneration, let fullImage {
            fullImageCache.setObject(
                fullImage,
                forKey: key,
                cost: Self.estimatedCost(for: fullImage)
            )
        }

        fullImageInProgressKeys.remove(hydratedKey)
        if let waiters = fullImageWaitingContinuations.removeValue(forKey: hydratedKey) {
            for continuation in waiters {
                continuation.resume(returning: fullImage)
            }
        }

        return snapshot.replacing(fullImage: fullImage)
    }

    private func snapshotMetadata(
        trackID: UUID,
        artworkData: Data,
        artworkChecksum: UInt64
    ) async -> ArtworkAssetSnapshot? {
        await getOrCreate(
            trackID: trackID,
            artworkData: artworkData,
            artworkChecksum: artworkChecksum
        ) { data, checksum in
            await Task.detached(priority: .utility) {
                Self.makeSnapshot(trackID: trackID, artworkData: data, checksum: checksum)
            }.value
        }
    }
    
    private nonisolated static func makeSnapshot(
        trackID: UUID,
        artworkData: Data,
        checksum: UInt64
    ) -> ArtworkAssetSnapshot? {
        guard !artworkData.isEmpty else { return nil }

        guard
            let imageSource = CGImageSourceCreateWithData(
                artworkData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let thumbnailImage = downsampledImage(source: imageSource, maxPixelSize: 160)
        let analysisSample = ArtworkColorExtractor.sampledBitmap(from: artworkData, side: 72)
        let palette =
            analysisSample.map { ArtworkColorExtractor.uiThemePalette(from: $0, targetCount: 4) }
            ?? []
        let richPalette =
            analysisSample.map { ArtworkColorExtractor.uiThemePaletteRich(from: $0, targetCount: 6) }
            ?? []
        let accentColor = palette.first
        let averageColor =
            analysisSample.flatMap { ArtworkColorExtractor.averageColor(from: $0) }
            ?? ArtworkColorExtractor.averageColor(from: artworkData)
        let dominantColor = accentColor ?? averageColor

        return ArtworkAssetSnapshot(
            trackID: trackID,
            artworkChecksum: checksum,
            thumbnailImage: thumbnailImage,
            fullImage: nil,
            dominantColor: dominantColor,
            accentColor: accentColor,
            palette: palette,
            richPalette: richPalette,
            averageColor: averageColor
        )
    }
    
    private nonisolated static func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func downsampledImage(
        source: CGImageSource,
        maxPixelSize: Int
    ) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        
        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private nonisolated static func estimatedCost(for image: NSImage) -> Int {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage.bytesPerRow * cgImage.height
        }

        return Int(image.size.width * image.size.height * 4)
    }
    
    private nonisolated static func computeChecksum(_ data: Data) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }
}
