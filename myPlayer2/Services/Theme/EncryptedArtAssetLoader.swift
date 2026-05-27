//
//  EncryptedArtAssetLoader.swift
//  myPlayer2
//
//  Loads encrypted first-party art assets from .kmgasset files.
//

import AppKit
import CryptoKit
import Foundation
import ImageIO

final class EncryptedArtAssetLoader: @unchecked Sendable {
    static let shared = EncryptedArtAssetLoader()

    private enum Constants {
        static let magic = Array("KMGASSET".utf8)
        static let version: UInt8 = 1
        static let algorithmAESGCM256: UInt8 = 1
        static let headerLength = 23
    }

    enum LoadError: Error, CustomStringConvertible {
        case missingFile(String)
        case badMagic(String)
        case unsupportedVersion(UInt8)
        case unsupportedAlgorithm(UInt8)
        case malformedHeader(String)
        case authenticationFailed(String)
        case imageDecodeFailed(String)

        var description: String {
            switch self {
            case .missingFile(let logicalName):
                return "missing encrypted art asset: \(logicalName)"
            case .badMagic(let logicalName):
                return "invalid encrypted art magic: \(logicalName)"
            case .unsupportedVersion(let version):
                return "unsupported encrypted art version: \(version)"
            case .unsupportedAlgorithm(let algorithm):
                return "unsupported encrypted art algorithm: \(algorithm)"
            case .malformedHeader(let logicalName):
                return "malformed encrypted art header: \(logicalName)"
            case .authenticationFailed(let logicalName):
                return "encrypted art authentication failed: \(logicalName)"
            case .imageDecodeFailed(let logicalName):
                return "encrypted art image decode failed: \(logicalName)"
            }
        }
    }

    private final class CGImageBox: NSObject {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let imageCache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 96
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    private init() {}

    func cgImage(logicalName: String, in bundle: Bundle?, maxPixel: Int) -> CGImage? {
        guard maxPixel > 0 else { return nil }
        let cacheKey = "\(logicalName)|px:\(maxPixel)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached.image
        }

        do {
            let image = try loadCGImage(logicalName: logicalName, in: bundle, maxPixel: maxPixel)
            imageCache.setObject(CGImageBox(image), forKey: cacheKey, cost: byteCost(for: image))
            return image
        } catch {
            Log.error("[EncryptedArtAssetLoader] \(error)", category: .theme)
            return nil
        }
    }

    func assetURL(logicalName: String, in bundle: Bundle?) -> URL? {
        for source in uniqueBundles([bundle, Bundle.main, Bundle(for: EncryptedArtAssetLoader.self)]) {
            if let url = encryptedURL(logicalName: logicalName, in: source) {
                return url
            }
        }
        return nil
    }

    func purgeCache() {
        imageCache.removeAllObjects()
    }

    private func loadCGImage(logicalName: String, in bundle: Bundle?, maxPixel: Int) throws -> CGImage {
        guard let url = assetURL(logicalName: logicalName, in: bundle) else {
            throw LoadError.missingFile(logicalName)
        }
        let fileData = try Data(contentsOf: url)
        let plaintext = try decrypt(fileData, logicalName: logicalName)
        guard let source = CGImageSourceCreateWithData(plaintext as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw LoadError.imageDecodeFailed(logicalName)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LoadError.imageDecodeFailed(logicalName)
        }
        return image
    }

    private func encryptedURL(logicalName: String, in bundle: Bundle) -> URL? {
        let normalized = logicalName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let directory = (normalized as NSString).deletingLastPathComponent
        let fileName = ((normalized as NSString).lastPathComponent as NSString).deletingPathExtension
        let subdirectory = directory.isEmpty ? "EncryptedArtAssets" : "EncryptedArtAssets/\(directory)"
        return bundle.url(forResource: fileName, withExtension: "kmgasset", subdirectory: subdirectory)
    }

    private func decrypt(_ data: Data, logicalName: String) throws -> Data {
        guard data.count >= Constants.headerLength else {
            throw LoadError.malformedHeader(logicalName)
        }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<Constants.magic.count]) == Constants.magic else {
            throw LoadError.badMagic(logicalName)
        }
        let version = bytes[8]
        guard version == Constants.version else {
            throw LoadError.unsupportedVersion(version)
        }
        let algorithm = bytes[9]
        guard algorithm == Constants.algorithmAESGCM256 else {
            throw LoadError.unsupportedAlgorithm(algorithm)
        }

        let nonceLength = Int(readUInt16(bytes, at: 11))
        let tagLength = Int(readUInt16(bytes, at: 13))
        let ciphertextLength = Int(readUInt64(bytes, at: 15))
        let expectedLength = Constants.headerLength + nonceLength + ciphertextLength + tagLength
        guard nonceLength > 0,
              tagLength > 0,
              ciphertextLength >= 0,
              expectedLength == data.count
        else {
            throw LoadError.malformedHeader(logicalName)
        }

        let nonceStart = Constants.headerLength
        let cipherStart = nonceStart + nonceLength
        let tagStart = cipherStart + ciphertextLength
        let nonceData = Data(bytes[nonceStart..<cipherStart])
        let ciphertext = Data(bytes[cipherStart..<tagStart])
        let tag = Data(bytes[tagStart..<expectedLength])

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealedBox, using: Self.assetKey())
        } catch {
            throw LoadError.authenticationFailed(logicalName)
        }
    }

    private static func assetKey() -> SymmetricKey {
        #if DEBUG
        if let key = keyFromEnvironment() {
            return key
        }
        #endif
        return publicKeyMaterial()
    }

    private static func keyFromEnvironment() -> SymmetricKey? {
        guard let hex = ProcessInfo.processInfo.environment["KMG_ART_ASSET_KEY_HEX"],
              hex.count == 64
        else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return SymmetricKey(data: Data(bytes))
    }

    private static func publicKeyMaterial() -> SymmetricKey {
        let : [UInt8] = []
        let : [UInt8] = []
        let : [UInt8] = []
        let : [UInt8] = []
        var material: [UInt8] = []
        for (index, byte) in (a + c + b + d).enumerated() {
            material.append(byte ^ UInt8((index &* 29 + 0x5d) & 0xff))
        }
        let digest = SHA256.hash(data: Data(material + Array("public-art-assets-v1".utf8)))
        return SymmetricKey(data: Data(digest))
    }

    private func uniqueBundles(_ bundles: [Bundle?]) -> [Bundle] {
        bundles
            .compactMap { $0 }
            .reduce(into: [Bundle]()) { partial, item in
                if !partial.contains(where: { $0.bundleURL == item.bundleURL }) {
                    partial.append(item)
                }
            }
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    private func byteCost(for image: CGImage) -> Int {
        max(1, image.bytesPerRow * image.height)
    }
}
