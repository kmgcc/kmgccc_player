import CryptoKit
import Foundation

/// A logical track within an unchanged physical source. Ranges use source time.
nonisolated struct AudioMediaSelection: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case cue, sacd }
    let kind: Kind
    let groupID: UUID
    let trackNumber: Int
    let start: Int64
    let length: Int64
    let timeScale: Int64
    var area: Int?
    var descriptorPath: String?
    var descriptorFingerprint: ReferencedFileFingerprint?
    var albumTitle: String?
    var albumArtist: String?
    var albumResourceID: UUID? = nil

    var duration: Double { Double(length) / Double(timeScale) }
    var startSeconds: Double { Double(start) / Double(timeScale) }
    var logicalKey: String { "\(groupID.uuidString):\(area ?? -1):\(trackNumber)" }

    func decodedRange(sampleRate: Double, totalFrames: Int64) throws -> Range<Int64> {
        guard timeScale > 0, start >= 0, length > 0, sampleRate.isFinite, sampleRate > 0,
              start <= Int64.max - length else { throw AudioDecodingError.invalidRange }
        let first = (Double(start) * sampleRate / Double(timeScale)).rounded(.down)
        let last = (Double(start + length) * sampleRate / Double(timeScale)).rounded(.down)
        guard first >= 0, last > first, last <= Double(totalFrames) + 1, last < Double(Int64.max) else {
            throw AudioDecodingError.invalidRange
        }
        return Int64(first)..<min(Int64(last), totalFrames)
    }

    static func groupID(for url: URL) -> UUID {
        let identity = (try? ReferencedFileIdentityProvider().fingerprint(for: url))?.identity
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = identity.flatMap { try? encoder.encode($0) }
            ?? Data(url.standardizedFileURL.path.utf8)
        var digest = Array(SHA256.hash(data: bytes).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
    }
}

nonisolated struct AudioProgramTrack: Sendable {
    let url: URL
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let selection: AudioMediaSelection
}
