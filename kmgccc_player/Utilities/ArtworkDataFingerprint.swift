//
//  ArtworkDataFingerprint.swift
//  myPlayer2
//
//  Lightweight signatures for UI identity checks.
//

import Foundation

nonisolated enum ArtworkDataFingerprint {
    private static let defaultSampleByteCount = 12

    static func sampledString(for data: Data?, sampleByteCount: Int = defaultSampleByteCount) -> String {
        guard let data, !data.isEmpty else { return "empty" }
        let sampleSize = min(sampleByteCount, data.count)
        return [
            "bytes=\(data.count)",
            "head=\(sampleHex(data.prefix(sampleSize)))",
            "tail=\(sampleHex(data.suffix(sampleSize)))",
        ].joined(separator: ":")
    }

    static func sampledHash(for data: Data?, sampleByteCount: Int = defaultSampleByteCount) -> UInt64 {
        guard let data, !data.isEmpty else { return 0 }
        let sampleSize = min(sampleByteCount, data.count)
        var hash: UInt64 = 1_469_598_103_934_665_603
        mix(UInt64(data.count), into: &hash)
        for byte in data.prefix(sampleSize) {
            mix(UInt64(byte), into: &hash)
        }
        mix(0xff, into: &hash)
        for byte in data.suffix(sampleSize) {
            mix(UInt64(byte), into: &hash)
        }
        return hash
    }

    private static func mix(_ value: UInt64, into hash: inout UInt64) {
        hash ^= value
        hash &*= 1_099_511_628_211
    }

    private static func sampleHex(_ bytes: Data.SubSequence) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
