//
//  CoverServiceModels.swift
//  myPlayer2
//
//  kmgccc_player - Shared Cover Service Models
//

import Foundation
import ImageIO

nonisolated enum CoverLookupConfiguration {
    static let netEasePreferredTimeout: TimeInterval = 8
    static let netEaseCandidatesTimeout: TimeInterval = 12
    static let qqMusicCandidatesTimeout: TimeInterval = 15
    static let sacadTimeout: TimeInterval = 18
    static let importPerTrackTimeout: TimeInterval = 30
    static let netEaseCandidateLimit = 5
    static let qqMusicCandidateLimit = 5
    static let automaticCoverConfidenceThreshold = 0.74
}

nonisolated enum CoverDownloadError: Error {
    case executableMissing(path: String)
    case processFailed(exitCode: Int32, message: String)
    case outputMissing
    case invalidImageData
    case cancelled
}

nonisolated enum NetEaseCoverError: Error {
    case badURL
    case requestFailed(underlying: Error)
    case decodingFailed(underlying: Error)
    case noResults
    case imageDownloadFailed(underlying: Error)
}

nonisolated enum CoverSource: Sendable {
    case sacad
    case netease
    case qqmusic

    var shortLabel: String {
        switch self {
        case .sacad: return "SC"
        case .netease: return "NE"
        case .qqmusic: return "QQ"
        }
    }

    var defaultConfidence: Double {
        switch self {
        case .netease: return 0.78
        case .sacad: return 0.74
        case .qqmusic: return 0.70
        }
    }
}

nonisolated enum CoverLookupTimeoutError: LocalizedError {
    case timedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Timed out after \(Int(seconds)) seconds"
        }
    }
}

nonisolated func withCoverLookupTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let timeoutNanoseconds = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw CoverLookupTimeoutError.timedOut(seconds: seconds)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// A cover image candidate with stable identity and resolution metadata.
nonisolated struct CoverCandidate: Identifiable, Equatable, Hashable, Sendable {
    let id: String  // Stable identity: "sacad:<normalized-query>" or "netease:<album-id>"
    let imageData: Data
    let resolution: Int  // Larger dimension (e.g., 1200 for 1200x1200)
    let width: Int
    let height: Int
    let source: CoverSource
    let sourceItemId: String?  // Album ID or query hash
    let confidence: Double
    let matchedTitle: String?
    let matchedArtist: String?
    let matchedAlbum: String?
    let imageURL: String?

    /// Creates a candidate with automatically computed dimensions.
    init(
        imageData: Data,
        source: CoverSource,
        sourceItemId: String?,
        confidence: Double? = nil,
        matchedTitle: String? = nil,
        matchedArtist: String? = nil,
        matchedAlbum: String? = nil,
        imageURL: String? = nil
    ) {
        self.id = "\(source):\(sourceItemId ?? "unknown")"
        self.imageData = imageData
        self.source = source
        self.sourceItemId = sourceItemId
        self.confidence = min(max(confidence ?? source.defaultConfidence, 0), 1)
        self.matchedTitle = matchedTitle
        self.matchedArtist = matchedArtist
        self.matchedAlbum = matchedAlbum
        self.imageURL = imageURL
        let (w, h) = Self.computeDimensions(from: imageData)
        self.width = w
        self.height = h
        self.resolution = max(w, h)
    }

    /// Creates a candidate with explicit dimensions (for performance when known).
    init(
        imageData: Data,
        source: CoverSource,
        sourceItemId: String?,
        width: Int,
        height: Int,
        confidence: Double? = nil,
        matchedTitle: String? = nil,
        matchedArtist: String? = nil,
        matchedAlbum: String? = nil,
        imageURL: String? = nil
    ) {
        self.id = "\(source):\(sourceItemId ?? "unknown")"
        self.imageData = imageData
        self.source = source
        self.sourceItemId = sourceItemId
        self.confidence = min(max(confidence ?? source.defaultConfidence, 0), 1)
        self.matchedTitle = matchedTitle
        self.matchedArtist = matchedArtist
        self.matchedAlbum = matchedAlbum
        self.imageURL = imageURL
        self.width = width
        self.height = height
        self.resolution = max(width, height)
    }

    /// Returns true if the image is square (width == height within tolerance).
    var isSquare: Bool {
        abs(width - height) <= 2
    }

    /// Compact resolution label: "1200" for square, "1200×800" for non-square.
    var resolutionLabel: String {
        if isSquare {
            return String(resolution)
        } else {
            return "\(width)×\(height)"
        }
    }

    var rankingScore: Double {
        let resolutionScore = min(Double(resolution), 2_000) / 2_000
        return confidence * 0.82 + resolutionScore * 0.18
    }

    private static func computeDimensions(from data: Data) -> (Int, Int) {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return (0, 0)
        }
        return (width, height)
    }

    // Equatable - compare by ID only for deduplication
    static func == (lhs: CoverCandidate, rhs: CoverCandidate) -> Bool {
        lhs.id == rhs.id
    }

    // Hashable - hash by ID only
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
