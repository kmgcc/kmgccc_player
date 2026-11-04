//
//  SidebarThumbnailLoader.swift
//  myPlayer2
//
//  Sidebar artist/album thumbnails: low-resolution decode, a bounded in-memory
//  cache, and the request model the sidebar uses for its prefetch window.
//

import AppKit
import Foundation

/// One sidebar thumbnail, resolved to a concrete artwork source.
///
/// `cacheIdentity` changes when the artwork content changes, so repeated
/// requests for the same image hit the memory cache even across library
/// refreshes. The identity is cheap to compute: a file snapshot or a sampled
/// fingerprint of embedded data.
nonisolated struct SidebarThumbnailRequest: Sendable {
    nonisolated enum Source: Sendable {
        case artworkData(Data)
        case fileURL(URL)
    }

    let cacheIdentity: String
    let artworkID: UUID
    let source: Source
    let targetPixelSize: CGSize
}

@MainActor
extension SidebarThumbnailRequest {
    static func artist(entry: ArtistEntry?, targetPixelSize: CGSize) -> Self? {
        guard let entry else { return nil }
        let sizePart = pixelSizeKey(for: targetPixelSize)

        if let data = entry.artworkData, !data.isEmpty {
            let identity = [
                "sidebar-artist-data",
                entry.id.uuidString,
                String(ArtworkDataFingerprint.sampledHash(for: data)),
                sizePart,
            ].joined(separator: "|")
            return Self(
                cacheIdentity: identity,
                artworkID: entry.id,
                source: .artworkData(data),
                targetPixelSize: targetPixelSize
            )
        }

        guard let fileURL = entry.existingArtworkURL else { return nil }
        let fileKey = ArtworkLoader.fileCacheKey(
            fileURL: fileURL,
            targetPixelSize: targetPixelSize
        )
        return Self(
            cacheIdentity: "sidebar-artist-file|\(fileKey)",
            artworkID: entry.id,
            source: .fileURL(fileURL),
            targetPixelSize: targetPixelSize
        )
    }

    static func album(
        album: AlbumSection,
        entry: AlbumEntry?,
        libraryVM: LibraryViewModel,
        targetPixelSize: CGSize
    ) async -> Self? {
        let sizePart = pixelSizeKey(for: targetPixelSize)

        if let entry {
            if let data = entry.artworkData, !data.isEmpty {
                let identity = [
                    "sidebar-album-data",
                    entry.id.uuidString,
                    String(ArtworkDataFingerprint.sampledHash(for: data)),
                    sizePart,
                ].joined(separator: "|")
                return Self(
                    cacheIdentity: identity,
                    artworkID: entry.id,
                    source: .artworkData(data),
                    targetPixelSize: targetPixelSize
                )
            }
            if let fileURL = entry.existingArtworkURL {
                let fileKey = ArtworkLoader.fileCacheKey(
                    fileURL: fileURL,
                    targetPixelSize: targetPixelSize
                )
                return Self(
                    cacheIdentity: "sidebar-album-file|\(fileKey)",
                    artworkID: entry.id,
                    source: .fileURL(fileURL),
                    targetPixelSize: targetPixelSize
                )
            }
        }

        guard let track = libraryVM.firstTrack(forAlbumGroupKey: album.key) else {
            return nil
        }
        if let fileURL = track.existingArtworkURL() {
            let fileKey = ArtworkLoader.fileCacheKey(
                fileURL: fileURL,
                targetPixelSize: targetPixelSize
            )
            return Self(
                cacheIdentity: "sidebar-album-track-file|\(fileKey)",
                artworkID: entry?.id ?? track.id,
                source: .fileURL(fileURL),
                targetPixelSize: targetPixelSize
            )
        }
        guard let data = await track.loadArtworkDataOffMainIfNeeded(), !data.isEmpty else {
            return nil
        }
        let identity = [
            "sidebar-album-track-data",
            track.id.uuidString,
            String(ArtworkDataFingerprint.sampledHash(for: data)),
            sizePart,
        ].joined(separator: "|")
        return Self(
            cacheIdentity: identity,
            artworkID: entry?.id ?? track.id,
            source: .artworkData(data),
            targetPixelSize: targetPixelSize
        )
    }

    private static func pixelSizeKey(for size: CGSize) -> String {
        "\(Int(size.width.rounded(.up)))x\(Int(size.height.rounded(.up)))"
    }
}

/// Owns the sidebar-only thumbnail memory cache. The underlying derivatives
/// remain in `ArtworkDerivativeCacheStore`, so this only avoids re-reading and
/// re-decoding images while the sidebar is scrolled.
@MainActor
final class SidebarThumbnailLoader {
    static let shared = SidebarThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    /// Kept in the caller's task so a row that scrolls away stops its decode
    /// instead of filling the queue. The cache only stores completed images.
    func image(
        for request: SidebarThumbnailRequest,
        derivativeStore: ArtworkDerivativeCacheStore
    ) async -> NSImage? {
        let key = request.cacheIdentity
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let image: NSImage?
        switch request.source {
        case .artworkData(let data):
            let cacheKey = ArtworkLoader.cacheKey(
                trackID: request.artworkID,
                checksum: ArtworkLoader.checksum(for: data),
                targetPixelSize: request.targetPixelSize
            )
            image = await ArtworkLoader.loadImage(
                artworkData: data,
                cacheKey: cacheKey,
                targetPixelSize: request.targetPixelSize,
                derivativeStore: derivativeStore
            )
        case .fileURL(let fileURL):
            let cacheKey = ArtworkLoader.fileCacheKey(
                fileURL: fileURL,
                targetPixelSize: request.targetPixelSize
            )
            image = await ArtworkLoader.loadImage(
                fileURL: fileURL,
                cacheKey: cacheKey,
                targetPixelSize: request.targetPixelSize,
                derivativeStore: derivativeStore
            )
        }

        guard let image else { return nil }
        let cost = Int(
            request.targetPixelSize.width
                * request.targetPixelSize.height
                * 4
        )
        cache.setObject(
            image,
            forKey: key as NSString,
            cost: max(1, cost)
        )
        return image
    }
}
