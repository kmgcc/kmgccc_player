//
//  ArtworkDerivativeCacheStore.swift
//  myPlayer2
//
//  Multi-size artwork derivative cache (memory + disk cache directory).
//

import AppKit
import Foundation
import ImageIO

private final class ArtworkDerivativeImageBox: NSObject {
    let image: NSImage

    nonisolated init(image: NSImage) {
        self.image = image
    }
}

actor ArtworkDerivativeCacheStore {
    static let shared = ArtworkDerivativeCacheStore()

    private let memoryCache = NSCache<NSString, ArtworkDerivativeImageBox>()
    private let fileManager = FileManager.default
    private let diskRootURL: URL
    private let maxDiskBytes: Int64 = 220 * 1024 * 1024
    private var writeCounter = 0

    private init() {
        memoryCache.countLimit = 720
        memoryCache.totalCostLimit = 96 * 1024 * 1024

        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        diskRootURL = cachesRoot
            .appendingPathComponent("kmgccc_player", isDirectory: true)
            .appendingPathComponent("PlaylistArtworkDerivatives", isDirectory: true)
        try? fileManager.createDirectory(at: diskRootURL, withIntermediateDirectories: true)
    }

    func image(
        for cacheKey: String,
        artworkData: Data,
        targetPixelSize: CGSize
    ) async -> NSImage? {
        if let memImage = memoryCache.object(forKey: cacheKey as NSString)?.image {
            return memImage
        }

        let diskURL = fileURL(for: cacheKey)
        if let diskImage = readImage(at: diskURL) {
            setMemoryImage(diskImage, cacheKey: cacheKey)
            touchItem(at: diskURL)
            return diskImage
        }

        let decoded = await Task.detached(priority: .utility) {
            downsampledImage(data: artworkData, targetPixelSize: targetPixelSize)
        }.value
        guard let decoded else { return nil }

        setMemoryImage(decoded, cacheKey: cacheKey)
        persist(image: decoded, to: diskURL)
        return decoded
    }

    func image(
        for cacheKey: String,
        artworkData: Data,
        maxPixelSize: Int
    ) async -> NSImage? {
        if let memImage = memoryCache.object(forKey: cacheKey as NSString)?.image {
            return memImage
        }

        let diskURL = fileURL(for: cacheKey)
        if let diskImage = readImage(at: diskURL) {
            setMemoryImage(diskImage, cacheKey: cacheKey)
            touchItem(at: diskURL)
            return diskImage
        }

        let decoded = await Task.detached(priority: .utility) {
            downsampledImage(data: artworkData, maxPixelSize: maxPixelSize)
        }.value
        guard let decoded else { return nil }

        setMemoryImage(decoded, cacheKey: cacheKey)
        persist(image: decoded, to: diskURL)
        return decoded
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskRootURL)
        try? fileManager.createDirectory(at: diskRootURL, withIntermediateDirectories: true)
    }

    private func setMemoryImage(_ image: NSImage, cacheKey: String) {
        memoryCache.setObject(
            ArtworkDerivativeImageBox(image: image),
            forKey: cacheKey as NSString,
            cost: estimatedCost(for: image)
        )
    }

    private func persist(image: NSImage, to url: URL) {
        guard let png = pngData(for: image) else { return }
        try? png.write(to: url, options: .atomic)

        writeCounter += 1
        if writeCounter.isMultiple(of: 26) {
            trimDiskIfNeeded()
        }
    }

    private func fileURL(for cacheKey: String) -> URL {
        let digest = stableDigest(cacheKey)
        return diskRootURL.appendingPathComponent("\(digest).png")
    }

    private func readImage(at url: URL) -> NSImage? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func touchItem(at url: URL) {
        let now = Date()
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    private func trimDiskIfNeeded() {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: diskRootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            )
        else { return }

        var records: [(url: URL, size: Int64, modified: Date)] = []
        records.reserveCapacity(urls.count)

        var totalSize: Int64 = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            totalSize += size
            records.append((url: url, size: size, modified: values?.contentModificationDate ?? .distantPast))
        }

        guard totalSize > maxDiskBytes else { return }
        let target = Int64(Double(maxDiskBytes) * 0.88)
        let sorted = records.sorted { $0.modified < $1.modified }
        var current = totalSize
        for item in sorted where current > target {
            try? fileManager.removeItem(at: item.url)
            current -= item.size
        }
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func estimatedCost(for image: NSImage) -> Int {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * 4)
    }

    private func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private nonisolated func downsampledImage(data: Data, targetPixelSize: CGSize) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let maxPixel = max(1, Int(max(targetPixelSize.width, targetPixelSize.height)))
    return downsampledImage(source: source, maxPixelSize: maxPixel)
}

private nonisolated func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return downsampledImage(source: source, maxPixelSize: maxPixelSize)
}

private nonisolated func downsampledImage(source: CGImageSource, maxPixelSize: Int) -> NSImage? {
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
