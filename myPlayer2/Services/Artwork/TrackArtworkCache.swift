//
//  TrackArtworkCache.swift
//  myPlayer2
//
//  Unified local-track artwork cache for playback surfaces.
//

import AppKit
import Foundation
import ImageIO

struct TrackArtworkSource: Sendable, Equatable {
    let trackID: UUID
    let artworkFileName: String?
    let artworkFileURL: URL?
    let inlineArtworkData: Data?
    let sourceKey: String

    nonisolated init?(
        trackID: UUID,
        artworkFileName: String?,
        artworkFileURL: URL?,
        inlineArtworkData: Data?
    ) {
        guard artworkFileURL != nil || inlineArtworkData?.isEmpty == false else { return nil }
        self.trackID = trackID
        self.artworkFileName = artworkFileName
        self.artworkFileURL = artworkFileURL
        self.inlineArtworkData = inlineArtworkData
        self.sourceKey = Self.makeSourceKey(
            trackID: trackID,
            artworkFileName: artworkFileName,
            artworkFileURL: artworkFileURL,
            inlineArtworkData: inlineArtworkData
        )
    }

    private nonisolated static func makeSourceKey(
        trackID: UUID,
        artworkFileName: String?,
        artworkFileURL: URL?,
        inlineArtworkData: Data?
    ) -> String {
        let version = "track-artwork-v1"
        if let artworkFileURL,
           let values = try? artworkFileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
           ) {
            let fileSize = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let modifiedNanos = Int64((modified * 1_000_000_000).rounded())
            let fileName = artworkFileName ?? artworkFileURL.lastPathComponent
            return [
                version,
                ArtworkColorExtractor.cacheVersion,
                trackID.uuidString,
                fileName,
                "\(fileSize)",
                "\(modifiedNanos)",
            ].joined(separator: "|")
        }

        let checksum = ArtworkAssetStore.checksum(for: inlineArtworkData)
        return [
            version,
            ArtworkColorExtractor.cacheVersion,
            trackID.uuidString,
            artworkFileName ?? "inline",
            "\(inlineArtworkData?.count ?? 0)",
            "\(checksum)",
        ].joined(separator: "|")
    }
}

extension Track {
    @MainActor
    func trackArtworkSource(fallbackData: Data? = nil) -> TrackArtworkSource? {
        TrackArtworkSource(
            trackID: id,
            artworkFileName: artworkFileName,
            artworkFileURL: resolvedArtworkURL(),
            inlineArtworkData: fallbackData ?? artworkData
        )
    }
}

actor TrackArtworkCache {
    static let shared = TrackArtworkCache()

    private let imageCache = NSCache<NSString, CachedArtworkImage>()
    private let fileManager = FileManager.default
    private var sourceDataTasks: [String: Task<Data?, Never>] = [:]
    private var imageTasks: [String: Task<NSImage?, Never>] = [:]

    private nonisolated var originalsRootURL: URL {
        StorageLocations.trackArtworkOriginalsURL
    }

    private nonisolated var derivativesRootURL: URL {
        StorageLocations.trackArtworkDerivativesURL
    }

    private init() {
        imageCache.countLimit = 256
        imageCache.totalCostLimit = 96 * 1024 * 1024
        try? FileManager.default.createDirectory(at: originalsRootURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: derivativesRootURL, withIntermediateDirectories: true)
    }

    func thumbnail(for source: TrackArtworkSource, maxPixelSize: Int = 160) async -> NSImage? {
        await image(for: source, variant: "thumbnail", maxPixelSize: maxPixelSize)
    }

    func fullImage(for source: TrackArtworkSource, maxPixelSize: Int = 1_400) async -> NSImage? {
        await image(for: source, variant: "full", maxPixelSize: maxPixelSize)
    }

    func snapshot(
        for source: TrackArtworkSource,
        fullImageMaxPixelSize: Int = 1_400
    ) async -> ArtworkAssetSnapshot? {
        guard let data = await sourceData(for: source) else { return nil }
        return await ArtworkAssetStore.shared.snapshot(
            trackID: source.trackID,
            artworkData: data,
            fullImageMaxPixelSize: fullImageMaxPixelSize
        )
    }

    func clearMemory() {
        imageCache.removeAllObjects()
        sourceDataTasks.removeAll()
        imageTasks.removeAll()
    }

    func sourceData(for source: TrackArtworkSource) async -> Data? {
        if let task = sourceDataTasks[source.sourceKey] {
            return await task.value
        }

        let cachedURL = originalFileURL(for: source)
        if let cachedData = try? Data(contentsOf: cachedURL), !cachedData.isEmpty {
            touchItem(at: cachedURL)
            return cachedData
        }

        let task = Task.detached(priority: .utility) { [cachedURL] () -> Data? in
            if let inline = source.inlineArtworkData, !inline.isEmpty {
                try? FileManager.default.createDirectory(
                    at: cachedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? inline.write(to: cachedURL, options: .atomic)
                return inline
            }

            guard let sourceURL = source.artworkFileURL,
                  let data = try? Data(contentsOf: sourceURL),
                  !data.isEmpty
            else {
                return nil
            }

            try? FileManager.default.createDirectory(
                at: cachedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cachedURL, options: .atomic)
            return data
        }

        sourceDataTasks[source.sourceKey] = task
        let data = await task.value
        sourceDataTasks[source.sourceKey] = nil
        return data
    }

    private func image(
        for source: TrackArtworkSource,
        variant: String,
        maxPixelSize: Int
    ) async -> NSImage? {
        let imageKey = "\(source.sourceKey)|\(variant)|px:\(max(1, maxPixelSize))"
        if let cached = imageCache.object(forKey: imageKey as NSString)?.image {
            return cached
        }

        let diskURL = derivativeFileURL(for: imageKey)
        if let diskImage = readImage(at: diskURL, maxPixelSize: maxPixelSize) {
            setMemoryImage(diskImage, key: imageKey)
            touchItem(at: diskURL)
            return diskImage
        }

        if let task = imageTasks[imageKey] {
            return await task.value
        }

        let task = Task { [weak self] () -> NSImage? in
            guard let self else { return nil }
            guard let data = await self.sourceData(for: source) else { return nil }
            let image = await Task.detached(priority: .utility) {
                Self.downsampledImage(data: data, maxPixelSize: maxPixelSize)
            }.value
            guard let image else { return nil }
            await self.persistImage(image, key: imageKey, diskURL: diskURL)
            return image
        }

        imageTasks[imageKey] = task
        let image = await task.value
        imageTasks[imageKey] = nil
        return image
    }

    private func persistImage(_ image: NSImage, key: String, diskURL: URL) {
        setMemoryImage(image, key: key)
        guard let png = Self.pngData(for: image) else { return }
        try? fileManager.createDirectory(
            at: diskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? png.write(to: diskURL, options: .atomic)
    }

    private func setMemoryImage(_ image: NSImage, key: String) {
        imageCache.setObject(
            CachedArtworkImage(image),
            forKey: key as NSString,
            cost: Self.estimatedCost(for: image)
        )
    }

    private func originalFileURL(for source: TrackArtworkSource) -> URL {
        originalsRootURL.appendingPathComponent("\(Self.stableDigest(source.sourceKey)).img")
    }

    private func derivativeFileURL(for imageKey: String) -> URL {
        derivativesRootURL.appendingPathComponent("\(Self.stableDigest(imageKey)).png")
    }

    private func readImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard fileManager.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              )
        else {
            return nil
        }
        return Self.downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private func touchItem(at url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private nonisolated static func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func downsampledImage(source: CGImageSource, maxPixelSize: Int) -> NSImage? {
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

    private nonisolated static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated static func estimatedCost(for image: NSImage) -> Int {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * 4)
    }

    private nonisolated static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
