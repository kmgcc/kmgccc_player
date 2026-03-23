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
    
    private let cache = NSCache<NSString, ArtworkAssetSnapshot>()
    private var inProgressKeys: Set<String> = []
    private var waitingContinuations: [String: [CheckedContinuation<ArtworkAssetSnapshot?, Never>]] = [:]
    
    func clearCache() {
        cache.removeAllObjects()
        inProgressKeys.removeAll()
        waitingContinuations.removeAll()
    }
    
    nonisolated static func checksum(for data: Data?) -> UInt64 {
        guard let data, !data.isEmpty else { return 0 }
        return computeChecksum(data)
    }
    
    func get(trackID: UUID, artworkChecksum: UInt64) -> ArtworkAssetSnapshot? {
        let key = "\(trackID.uuidString)-\(artworkChecksum)"
        return cache.object(forKey: key as NSString)
    }
    
    func snapshot(trackID: UUID, artworkData: Data) async -> ArtworkAssetSnapshot? {
        let checksum = Self.computeChecksum(artworkData)
        return await getOrCreate(
            trackID: trackID,
            artworkData: artworkData,
            artworkChecksum: checksum
        ) { data, checksum in
            Self.makeSnapshot(trackID: trackID, artworkData: data, checksum: checksum)
        }
    }
    
    func cache(_ snapshot: ArtworkAssetSnapshot) {
        var cost = 0
        if snapshot.thumbnailImage != nil { cost += 50 * 1024 }
        if snapshot.fullImage != nil { cost += 200 * 1024 }
        cache.setObject(snapshot, forKey: snapshot.cacheKey as NSString, cost: cost)
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
    
    private nonisolated static func makeSnapshot(
        trackID: UUID,
        artworkData: Data,
        checksum: UInt64
    ) -> ArtworkAssetSnapshot? {
        guard !artworkData.isEmpty else { return nil }
        
        let thumbnailImage = downsampledImage(data: artworkData, maxPixelSize: 160)
        let fullImage = downsampledImage(data: artworkData, maxPixelSize: 1400)
        let palette = ArtworkColorExtractor.uiThemePalette(from: artworkData, maxColors: 4)
        let richPalette = ArtworkColorExtractor.uiThemePaletteRich(from: artworkData, desiredCount: 6)
        let accentColor = palette.first
        let averageColor = ArtworkColorExtractor.averageColor(from: artworkData)
        let dominantColor = accentColor ?? averageColor
        
        return ArtworkAssetSnapshot(
            trackID: trackID,
            artworkChecksum: checksum,
            thumbnailImage: thumbnailImage,
            fullImage: fullImage,
            dominantColor: dominantColor,
            accentColor: accentColor,
            palette: palette,
            richPalette: richPalette,
            averageColor: averageColor
        )
    }
    
    private nonisolated static func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        
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
