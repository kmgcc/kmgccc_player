import Foundation

/// JSON-compatible catalog values preserve new provider fields without a
/// database migration every time a service adds a credit or an artwork trait.
nonisolated indirect enum MusicMetadataValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: Self]), array([Self]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try container.decode([Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var text: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var strings: [String] {
        if case .array(let values) = self { return values.compactMap(\.text) }
        return text.map { [$0] } ?? []
    }

    var dictionary: [String: Self]? {
        if case .object(let values) = self { return values }
        return nil
    }
}

nonisolated struct MusicEnrichmentQuery: Codable, Equatable, Sendable {
    var key: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var appleSongID: String? = nil
    var appleAlbumID: String? = nil
    var storefront: String? = nil
    var isrc: String? = nil
    var seedAttributes: [String: MusicMetadataValue]? = nil
    var storedMotionArtwork: TrackMotionArtwork? = nil
    var albumArtist: String? = nil
}

nonisolated struct MotionArtworkDescriptor: Codable, Equatable, Sendable {
    var kind: String
    var url: String
    var width: Int? = nil
    var height: Int? = nil
}

nonisolated struct MusicEnrichmentResult: Codable, Equatable, Sendable {
    var source: String
    var songID: String? = nil
    var albumID: String? = nil
    var storefront: String? = nil
    var confidence: Double? = nil
    var attributes: [String: MusicMetadataValue]? = nil
    var resources: [String: MusicMetadataValue]? = nil
    var lyricsTTML: String? = nil
    var motion: [MotionArtworkDescriptor]? = nil
    var matchKind: String? = nil
    var cacheTimestamp: MusicMetadataValue? = nil
    var lyricsLocalizations: [String: String]? = nil
}

/// Where an explicit motion artwork choice applies.
nonisolated enum MotionArtworkScope: String, Sendable, CaseIterable, Identifiable {
    /// Every song of the album that has no choice of its own.
    case album
    /// This song only; the album's artwork stays as it is.
    case track

    var id: String { rawValue }
}

nonisolated struct StoredMotionArtwork: Codable, Equatable, Sendable {
    var kind: String
    var relativePath: String
    var sourceURL: String
    var startTime: Double
    var duration: Double
    var width: Int?
    var height: Int?
}

nonisolated struct MotionArtworkResource: Equatable, Sendable {
    var url: URL
    var startTime: Double
    var duration: Double
}

nonisolated struct MusicEnrichmentRecord: Codable, Equatable, Sendable {
    var version = 2
    var query: MusicEnrichmentQuery
    var results: [MusicEnrichmentResult] = []
    var assets: [StoredMotionArtwork] = []
    var manualMotionSelection: MusicEnrichmentResult? = nil
    var manualAttributes: [String: MusicMetadataValue]? = nil
    var albumMotionIdentity: String? = nil
    var updatedAt = Date()

    mutating func merge(_ result: MusicEnrichmentResult) {
        // Keep arrival order: a late provider fills gaps instead of replacing
        // already visible information. Retain every provider's full snapshot.
        if let index = results.firstIndex(where: { $0.source == result.source }) {
            results[index] = result
        } else {
            results.append(result)
        }
        updatedAt = Date()
    }

    var attributes: [String: MusicMetadataValue] {
        var values = manualAttributes ?? [:]
        for (key, value) in query.seedAttributes ?? [:] where values[key] == nil { values[key] = value }
        for result in results {
            for (key, value) in result.attributes ?? [:] where values[key] == nil || (values[key] == .null && manualAttributes?[key] == nil) {
                values[key] = value
            }
        }
        return values
    }

    var resolvedAppleSongID: String? {
        query.appleSongID ?? results.first(where: { $0.source == "appleWeb" || $0.source == "appleCache" })?.songID
    }

    var attributeSources: [String: String] {
        var sources = (manualAttributes ?? [:]).mapValues { _ in "userMetadata" }
        var values = manualAttributes ?? [:]
        for (key, value) in query.seedAttributes ?? [:] where values[key] == nil {
            values[key] = value
            sources[key] = "originalMetadata"
        }
        for result in results {
            for (key, value) in result.attributes ?? [:] where values[key] == nil || (values[key] == .null && manualAttributes?[key] == nil) {
                values[key] = value
                sources[key] = result.source
            }
        }
        return sources
    }

    var lyricsSource: String? {
        guard let text = lyricsTTML else { return nil }
        return results.first(where: { $0.lyricsTTML == text })?.source
    }

    var lyricsTTML: String? {
        results.compactMap(\.lyricsTTML).filter { !$0.isEmpty }.max {
            $0.components(separatedBy: "<span").count < $1.components(separatedBy: "<span").count
        }
    }

    var motionDescriptors: [MotionArtworkDescriptor] {
        var seen = Set<String>()
        let descriptors = manualMotionSelection?.motion ?? results.flatMap { $0.motion ?? [] }
        return descriptors.filter { seen.insert($0.url).inserted }
    }
}

/// Catalog identities remain distinct even when display names happen to match.
nonisolated struct MusicAlbumMotionIdentity: Sendable, Equatable {
    var key: String
    var catalogAlbumID: String?
    var fallbackKey: String?

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The first credited artist: "A, B", "A & B" and "A feat. B" all name A.
    static func primaryArtist(_ value: String) -> String {
        let pattern = #"[,，、;；/&＆（(]|\s+(?:feat\.?|ft\.?|featuring|with|x|×|vs\.?)\s+"#
        let first = value.range(of: pattern, options: [.regularExpression, .caseInsensitive])
            .map { String(value[..<$0.lowerBound]) } ?? value
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }
}

extension MusicEnrichmentRecord {
    nonisolated var motionAlbumIdentity: MusicAlbumMotionIdentity? {
        let album = MusicAlbumMotionIdentity.normalized(query.album)
        // Without an album artist, a song credited "A, B" belongs with A's album.
        let artist = [query.albumArtist, query.seedAttributes?["albumArtistName"]?.text,
                      MusicAlbumMotionIdentity.primaryArtist(query.artist)]
            .compactMap { $0 }.map(MusicAlbumMotionIdentity.normalized).first(where: { !$0.isEmpty }) ?? ""
        let fallback = album.isEmpty || artist.isEmpty ? nil : "named:\(album)\u{0}\(artist)"
        let inheritedCatalog = albumMotionIdentity.flatMap { $0.hasPrefix("apple:") ? String($0.dropFirst(6)) : nil }
        // A song's own choice may come from another release; it says nothing about the local album.
        let storedCatalog = query.storedMotionArtwork.flatMap { $0.isUserSelected ? nil : $0.catalogAlbumID }
        let catalog = query.appleAlbumID ?? results.first(where: { $0.source == "appleWeb" || $0.source == "appleCache" })?.albumID ?? storedCatalog ?? inheritedCatalog
        if let catalog, !catalog.isEmpty {
            return MusicAlbumMotionIdentity(key: "apple:\(catalog)", catalogAlbumID: catalog, fallbackKey: fallback)
        }
        guard let fallback else { return nil }
        return MusicAlbumMotionIdentity(key: fallback, catalogAlbumID: nil, fallbackKey: fallback)
    }
}

/// A compact track-sidecar reference, while full provider responses remain in
/// the library enrichment record. Media files move with the track directory.
nonisolated struct TrackMotionArtwork: Codable, Equatable, Sendable {
    var assets: [StoredMotionArtwork]
    var isUserSelected: Bool
    var catalogAlbumID: String?
    var albumIdentity: String? = nil

    init(snapshot: MusicEnrichmentSnapshot) {
        assets = snapshot.record.assets
        isUserSelected = snapshot.record.manualMotionSelection != nil
        catalogAlbumID = snapshot.record.manualMotionSelection?.albumID ?? snapshot.record.motionAlbumIdentity?.catalogAlbumID
        albumIdentity = isUserSelected ? nil : snapshot.record.albumMotionIdentity
    }

    /// The album's artwork as shown by a song without its own choice.
    init(albumAssets: [StoredMotionArtwork], catalogAlbumID: String?, albumIdentity: String) {
        assets = albumAssets
        isUserSelected = false
        self.catalogAlbumID = catalogAlbumID
        self.albumIdentity = albumIdentity
    }

    func resource(kind: String, libraryRootURL: URL) -> MotionArtworkResource? {
        guard let asset = assets.first(where: { $0.kind == kind }),
              !asset.relativePath.hasPrefix("/"),
              !asset.relativePath.split(separator: "/").contains("..") else { return nil }
        let libraryRelative = asset.relativePath.hasPrefix("Tracks/") || asset.relativePath.hasPrefix("Enrichment/")
        let base = libraryRelative ? libraryRootURL : libraryRootURL.appendingPathComponent("Enrichment")
        let url = base.appendingPathComponent(asset.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return MotionArtworkResource(url: url, startTime: asset.startTime, duration: asset.duration)
    }
}

nonisolated struct MusicEnrichmentSnapshot: Equatable, Sendable {
    var record: MusicEnrichmentRecord
    var squareArtwork: MotionArtworkResource?
    var tallArtwork: MotionArtworkResource?
    var artworkData: Data? = nil
    var lyricsTTML: String? = nil
    var lyricsIdentity: String? = nil

    var attributes: [String: MusicMetadataValue] { record.attributes }
}
