//
//  ArtworkAssetStore.swift
//  myPlayer2
//
//  kmgccc_player - Thread-safe artwork asset caching store
//

import AppKit
import Foundation

actor ArtworkAssetStore {
    static let shared = ArtworkAssetStore()
    
    private let cache = NSCache<NSString, ArtworkAssetSnapshot>()
    private var inProgressKeys: Set<String> = []
    private var waitingContinuations: [String: [CheckedContinuation<ArtworkAssetSnapshot?, Never>]] = [:]
    
    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024
    }
    
    func get(trackID: UUID, artworkChecksum: UInt64) -> ArtworkAssetSnapshot? {
        let key = "\(trackID.uuidString)-\(artworkChecksum)"
        return cache.object(forKey: key as NSString)
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
        extract: @Sendable @escaping (Data) async -> ArtworkAssetSnapshot?
    ) async -> ArtworkAssetSnapshot? {
        let checksum = computeChecksum(artworkData)
        let key = "\(trackID.uuidString)-\(checksum)"
        
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        
        if inProgressKeys.contains(key) {
            return await withCheckedContinuation { continuation in
                waitingContinuations[key, default: []].append(continuation)
            }
        }
        
        inProgressKeys.insert(key)
        let result = await extract(artworkData)
        
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
    
    private func computeChecksum(_ data: Data) -> UInt64 {
        guard data.count >= 8 else {
            var padded = data
            while padded.count < 8 { padded.append(0) }
            return padded.withUnsafeBytes { $0.load(as: UInt64.self) }
        }
        return data.withUnsafeBytes { $0.load(as: UInt64.self) }
    }
}
