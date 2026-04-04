//
//  CoverServiceModels.swift
//  myPlayer2
//
//  kmgccc_player - Shared Cover Service Models
//

import AppKit
import Foundation

enum CoverDownloadError: Error {
    case executableMissing(path: String)
    case processFailed(exitCode: Int32, message: String)
    case outputMissing
    case invalidImageData
    case cancelled
}

enum NetEaseCoverError: Error {
    case badURL
    case requestFailed(underlying: Error)
    case decodingFailed(underlying: Error)
    case noResults
    case imageDownloadFailed(underlying: Error)
}

enum CoverSource {
    case sacad
    case netease
}

/// A cover image candidate with stable identity and resolution metadata.
struct CoverCandidate: Identifiable, Equatable, Hashable {
    let id: String  // Stable identity: "sacad:<normalized-query>" or "netease:<album-id>"
    let imageData: Data
    let resolution: Int  // Larger dimension (e.g., 1200 for 1200x1200)
    let width: Int
    let height: Int
    let source: CoverSource
    let sourceItemId: String?  // Album ID or query hash

    /// Creates a candidate with automatically computed dimensions.
    init(imageData: Data, source: CoverSource, sourceItemId: String?) {
        self.id = "\(source):\(sourceItemId ?? "unknown")"
        self.imageData = imageData
        self.source = source
        self.sourceItemId = sourceItemId
        let (w, h) = Self.computeDimensions(from: imageData)
        self.width = w
        self.height = h
        self.resolution = max(w, h)
    }

    /// Creates a candidate with explicit dimensions (for performance when known).
    init(imageData: Data, source: CoverSource, sourceItemId: String?, width: Int, height: Int) {
        self.id = "\(source):\(sourceItemId ?? "unknown")"
        self.imageData = imageData
        self.source = source
        self.sourceItemId = sourceItemId
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

    private static func computeDimensions(from data: Data) -> (Int, Int) {
        guard let image = NSImage(data: data),
              let rep = image.representations.first else {
            return (0, 0)
        }
        return (rep.pixelsWide, rep.pixelsHigh)
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
