//
//  PlaylistArtworkPipeline.swift
//  myPlayer2
//
//  Unified artwork pipeline for row/header/effect rendering.
//

import AppKit
import Foundation

enum PlaylistArtworkVariant: String, Sendable {
    case rowLow
    case rowHigh
    case header
    case haloSeed
}

struct PlaylistArtworkRequest: Sendable {
    let sourceIdentity: String
    let variant: PlaylistArtworkVariant
    let artworkData: Data?
    let fileURL: URL?
    let pixelSize: CGSize

    nonisolated var cacheKey: String {
        "\(sourceIdentity)|\(variant.rawValue)|\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }
}

actor PlaylistArtworkPipeline {
    static let shared = PlaylistArtworkPipeline()

    private let memoryCache = NSCache<NSString, CachedArtworkImage>()
    private let decodeGate = ArtworkDecodeGate(maxConcurrent: 6)

    private init() {
        memoryCache.countLimit = 720
        memoryCache.totalCostLimit = 96 * 1024 * 1024
    }

    func cachedImage(for request: PlaylistArtworkRequest) -> NSImage? {
        memoryCache.object(forKey: request.cacheKey as NSString)?.image
    }

    func load(_ request: PlaylistArtworkRequest) async -> NSImage? {
        if let cached = cachedImage(for: request) {
            return cached
        }

        guard !Task.isCancelled else { return nil }

        let maxPixel = max(request.pixelSize.width, request.pixelSize.height)
        
        if maxPixel <= 160, let trackID = parseTrackID(from: request.sourceIdentity) {
            let checksum = request.artworkData.flatMap { ArtworkAssetStore.checksum(for: $0) } ?? 0
            if let snapshot = await ArtworkAssetStore.shared.get(trackID: trackID, artworkChecksum: checksum),
               let thumbnail = snapshot.thumbnailImage {
                memoryCache.setObject(
                    CachedArtworkImage(thumbnail),
                    forKey: request.cacheKey as NSString,
                    cost: max(1, Int(request.pixelSize.width * request.pixelSize.height * 4))
                )
                return thumbnail
            }
        }

        guard let sourceData = await sourceData(for: request) else {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        // Acquire decode slot with cancellation support
        let (acquired, _) = await decodeGate.acquire()
        guard acquired else {
            // Cancelled while waiting for slot
            return nil
        }

        // Ensure release is called exactly once after successful acquire
        defer { Task { await decodeGate.release() } }

        // Double-check cancellation after acquiring slot
        guard !Task.isCancelled else {
            return nil
        }

        let image = await ArtworkDerivativeCacheStore.shared.image(
            for: request.cacheKey,
            artworkData: sourceData,
            targetPixelSize: request.pixelSize
        )

        guard let image else {
            return nil
        }

        guard !Task.isCancelled else {
            return nil
        }

        memoryCache.setObject(
            CachedArtworkImage(image),
            forKey: request.cacheKey as NSString,
            cost: max(1, Int(request.pixelSize.width * request.pixelSize.height * 4))
        )

        return image
    }
    
    private func parseTrackID(from sourceIdentity: String) -> UUID? {
        guard sourceIdentity.hasPrefix("row-") else { return nil }
        let parts = sourceIdentity.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        let uuidString = parts[1...].dropLast().joined(separator: "-")
        return UUID(uuidString: uuidString)
    }

    @discardableResult
    nonisolated func prefetch(_ requests: [PlaylistArtworkRequest]) -> Task<Void, Never>? {
        guard !requests.isEmpty else { return nil }
        return Task.detached(priority: .background) {
            for request in requests {
                if Task.isCancelled { return }
                _ = await self.load(request)
            }
        }
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    private func sourceData(for request: PlaylistArtworkRequest) async -> Data? {
        if let artworkData = request.artworkData, !artworkData.isEmpty {
            return artworkData
        }
        guard let fileURL = request.fileURL else { return nil }
        return await Task.detached(priority: .utility) {
            try? Data(contentsOf: fileURL)
        }.value
    }
}

extension PlaylistArtworkPipeline {
    nonisolated static func rowSourceIdentity(trackID: UUID, artworkData: Data?, artworkFileURL: URL? = nil) -> String {
        let checksum = ArtworkLoader.checksum(for: artworkData)
        let fileHash = artworkFileURL?.path.hashValue ?? 0
        return "row-\(trackID.uuidString)-\(checksum)-\(fileHash)"
    }

    nonisolated static func rowLowRequest(
        trackID: UUID,
        artworkData: Data?,
        artworkFileURL: URL? = nil,
        artworkIdentity: String? = nil,
        logicalSize: CGFloat,
        scale: CGFloat
    ) -> PlaylistArtworkRequest {
        let side = max(22, logicalSize * 0.55) * max(1, scale)
        return PlaylistArtworkRequest(
            sourceIdentity: artworkIdentity ?? rowSourceIdentity(trackID: trackID, artworkData: artworkData, artworkFileURL: artworkFileURL),
            variant: .rowLow,
            artworkData: artworkData,
            fileURL: artworkFileURL,
            pixelSize: CGSize(width: side, height: side)
        )
    }

    nonisolated static func rowHighRequest(
        trackID: UUID,
        artworkData: Data?,
        artworkFileURL: URL? = nil,
        artworkIdentity: String? = nil,
        logicalSize: CGFloat,
        scale: CGFloat
    ) -> PlaylistArtworkRequest {
        let side = max(1, logicalSize) * max(1, scale)
        return PlaylistArtworkRequest(
            sourceIdentity: artworkIdentity ?? rowSourceIdentity(trackID: trackID, artworkData: artworkData, artworkFileURL: artworkFileURL),
            variant: .rowHigh,
            artworkData: artworkData,
            fileURL: artworkFileURL,
            pixelSize: CGSize(width: side, height: side)
        )
    }

    nonisolated static func headerRequest(
        artworkIdentity: String,
        artworkData: Data?,
        fileURL: URL?
    ) -> PlaylistArtworkRequest {
        PlaylistArtworkRequest(
            sourceIdentity: "header-\(artworkIdentity)",
            variant: .header,
            artworkData: artworkData,
            fileURL: fileURL,
            pixelSize: CGSize(width: 640, height: 640)
        )
    }

    nonisolated static func haloSeedRequest(
        artworkIdentity: String,
        artworkData: Data?,
        fileURL: URL?,
        pixelSide: Int = 192
    ) -> PlaylistArtworkRequest {
        let side = max(96, pixelSide)
        return PlaylistArtworkRequest(
            sourceIdentity: "halo-\(artworkIdentity)",
            variant: .haloSeed,
            artworkData: artworkData,
            fileURL: fileURL,
            pixelSize: CGSize(width: side, height: side)
        )
    }
}
