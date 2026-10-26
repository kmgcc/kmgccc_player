import CryptoKit
import Foundation

/// Original enrichment data belongs to the library, outside Cache. Clearing
/// render caches never discards catalog snapshots, lyrics or downloaded video.
actor MusicEnrichmentStore {
    nonisolated let rootURL: URL
    private var isClosed = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL) {
        self.rootURL = rootURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load(key: String) throws -> MusicEnrichmentRecord? {
        guard !isClosed else { return nil }
        let url = recordURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try decoder.decode(MusicEnrichmentRecord.self, from: Data(contentsOf: url))
        return record.version >= 2 ? try resolveMotion(in: record) : record
    }

    func save(_ input: MusicEnrichmentRecord) throws {
        guard !isClosed else { return }
        let record = try resolveMotion(in: input)
        let url = recordURL(key: record.query.key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    /// Read/modify/write runs in one actor turn. Independent downloads cannot
    /// overwrite a manual decision committed while their network work waited.
    func updateRecord(
        key: String,
        fallbackQuery: MusicEnrichmentQuery,
        alignQuery: Bool = false,
        mutation: @Sendable (inout MusicEnrichmentRecord) throws -> Void
    ) throws -> MusicEnrichmentRecord {
        guard !isClosed else { throw CancellationError() }
        try Task.checkCancellation()
        var record = try load(key: key) ?? MusicEnrichmentRecord(query: fallbackQuery)
        if alignQuery {
            let old = record.query
            let sameIdentity = record.version >= 2 && old.title == fallbackQuery.title
                && old.artist == fallbackQuery.artist && old.album == fallbackQuery.album
                && old.albumArtist == fallbackQuery.albumArtist
                && abs(old.duration - fallbackQuery.duration) < 0.01
                && old.appleSongID == fallbackQuery.appleSongID && old.appleAlbumID == fallbackQuery.appleAlbumID
                && old.isrc == fallbackQuery.isrc && old.storefront == fallbackQuery.storefront
            if !sameIdentity {
                let attributes = record.manualAttributes
                let selection = record.manualMotionSelection
                let assets = selection == nil ? [] : record.assets
                record = MusicEnrichmentRecord(query: fallbackQuery)
                record.query.storedMotionArtwork = nil
                record.manualAttributes = attributes
                record.manualMotionSelection = selection
                record.assets = assets
                try removeArtwork(key: key)
            } else {
                record.query = fallbackQuery
            }
            if record.manualMotionSelection == nil, let stored = record.query.storedMotionArtwork {
                if record.assets.isEmpty { record.assets = stored.assets }
                if stored.isUserSelected {
                    record.manualMotionSelection = MusicEnrichmentResult(
                        source: "manual", albumID: stored.catalogAlbumID,
                        motion: stored.assets.map { MotionArtworkDescriptor(kind: $0.kind, url: $0.sourceURL, width: $0.width, height: $0.height) }
                    )
                }
            }
        }
        try mutation(&record)
        record.updatedAt = Date()
        try save(record)
        return record
    }

    /// Bounded discovery includes external identities which have no local Track.
    /// Offset follows stable record filenames, so corrupt files can be skipped
    /// without losing the next page or exposing filesystem paths to Automation.
    func listRecords(offset: Int, limit: Int) throws -> (records: [MusicEnrichmentRecord], nextOffset: Int?) {
        guard !isClosed else { return ([], nil) }
        let directory = rootURL.appendingPathComponent("Records", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], nil) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let start = min(max(0, offset), files.count)
        let end = min(files.count, start + max(1, min(100, limit)))
        let records = files[start..<end].compactMap { url -> MusicEnrichmentRecord? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(MusicEnrichmentRecord.self, from: data)
        }
        return (records, end < files.count ? end : nil)
    }

    func importMotion(
        from temporaryURL: URL,
        descriptor: MotionArtworkDescriptor,
        startTime: Double,
        duration: Double,
        queryKey: String? = nil,
        fileExtension: String = "mp4",
        albumIdentity: String? = nil
    ) throws -> StoredMotionArtwork? {
        guard !isClosed else { return nil }
        let suppliedExtension = fileExtension.lowercased()
        let ext = !suppliedExtension.isEmpty && suppliedExtension.count <= 12 && suppliedExtension.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) ? suppliedExtension : "mp4"
        let relativePath: String
        let target: URL
        if let albumIdentity {
            relativePath = "AlbumAssets/\(Self.digest(albumIdentity))/\(descriptor.kind == "tall" ? "tall" : "square")-\(Self.digest(descriptor.url).prefix(16)).\(ext)"
            target = rootURL.appendingPathComponent(relativePath)
        } else if let queryKey, queryKey.hasPrefix("track:"),
           let trackID = UUID(uuidString: String(queryKey.dropFirst(6))) {
            relativePath = "Tracks/\(trackID.uuidString)/motion-\(descriptor.kind == "tall" ? "tall" : "square")-\(Self.digest(descriptor.url).prefix(16)).\(ext)"
            target = rootURL.deletingLastPathComponent().appendingPathComponent(relativePath)
        } else {
            relativePath = "Assets/\(Self.digest(descriptor.url)).\(ext)"
            target = rootURL.appendingPathComponent(relativePath)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            // Copy then atomically rename on the library volume. A partial
            // download can never become the persisted asset.
            let staging = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: temporaryURL, to: staging)
            try FileManager.default.moveItem(at: staging, to: target)
        }
        return StoredMotionArtwork(
            kind: descriptor.kind, relativePath: relativePath, sourceURL: descriptor.url,
            startTime: startTime, duration: duration, width: descriptor.width, height: descriptor.height
        )
    }

    nonisolated private struct AlbumMotionRecord: Codable {
        var identity: String
        var catalogAlbumID: String?
        var assets: [StoredMotionArtwork]
        var alias: String? = nil
        var updatedAt: Date? = nil
        /// An explicit choice (including "none") that the automatic pass never replaces.
        var isUserSelected: Bool? = nil
    }

    /// What every song of an album shows unless it has its own choice.
    nonisolated struct AlbumMotionState: Sendable, Equatable {
        var key: String
        var assets: [StoredMotionArtwork]
        var isUserSelected: Bool
    }

    private func albumURL(_ key: String) -> URL {
        rootURL.appendingPathComponent("Albums").appendingPathComponent("\(Self.digest(key)).json")
    }

    private func albumRecord(_ key: String) throws -> AlbumMotionRecord? {
        let url = albumURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try decoder.decode(AlbumMotionRecord.self, from: Data(contentsOf: url))
        if let alias = record.alias, alias != key {
            let target = albumURL(alias)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            return try decoder.decode(AlbumMotionRecord.self, from: Data(contentsOf: target))
        }
        return record
    }

    private func saveAlbum(_ record: AlbumMotionRecord, key: String? = nil) throws {
        let url = albumURL(key ?? record.identity)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }

    private func assetURL(_ asset: StoredMotionArtwork) -> URL? {
        guard !asset.relativePath.hasPrefix("/"), !asset.relativePath.split(separator: "/").contains("..") else { return nil }
        let libraryRelative = asset.relativePath.hasPrefix("Tracks/") || asset.relativePath.hasPrefix("Enrichment/")
        return (libraryRelative ? rootURL.deletingLastPathComponent() : rootURL).appendingPathComponent(asset.relativePath)
    }

    private func assetExists(_ asset: StoredMotionArtwork) -> Bool {
        assetURL(asset).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The album record a song resolves to: its catalog album, or the named
    /// album when the catalog is unknown or the named record has no other catalog.
    private func resolvedAlbum(_ identity: MusicAlbumMotionIdentity) throws -> (key: String, catalogID: String?, shared: AlbumMotionRecord?) {
        var shared = try albumRecord(identity.key)
        if shared == nil, let fallback = identity.fallbackKey, fallback != identity.key,
           let named = try albumRecord(fallback), named.catalogAlbumID == nil || named.catalogAlbumID == identity.catalogAlbumID {
            shared = named
        }
        let key = identity.catalogAlbumID == nil ? (shared?.identity ?? identity.key) : identity.key
        return (key, identity.catalogAlbumID ?? shared?.catalogAlbumID, shared)
    }

    private func writeAlbum(_ album: AlbumMotionRecord, fallback: String?) throws {
        try saveAlbum(album)
        try writeAlias(fallback, to: album.identity, catalogID: album.catalogAlbumID)
    }

    /// Songs known only by album name follow the catalog album's record.
    private func writeAlias(_ fallback: String?, to key: String, catalogID: String?) throws {
        guard let fallback, fallback != key else { return }
        let existing = try albumRecord(fallback)
        if existing == nil || existing?.catalogAlbumID == nil || existing?.catalogAlbumID == catalogID {
            try saveAlbum(AlbumMotionRecord(identity: fallback, catalogAlbumID: catalogID, assets: [], alias: key), key: fallback)
        }
    }

    /// Motion artwork belongs to the album; every song without its own choice
    /// shows the album's. Files under AlbumAssets are owned by the album record,
    /// while legacy per-track originals are copied in lazily and retained.
    func resolveMotion(in input: MusicEnrichmentRecord) throws -> MusicEnrichmentRecord {
        guard !isClosed else { return input }
        var record = input
        guard record.manualMotionSelection == nil else { record.albumMotionIdentity = nil; return record }
        guard record.version >= 2 else { return record }
        guard let identity = record.motionAlbumIdentity else { return record }
        let (resolvedKey, resolvedCatalogID, shared) = try resolvedAlbum(identity)
        let userSelected = shared?.isUserSelected == true
        var assets = shared?.assets.filter(assetExists) ?? []
        if !userSelected {
            for asset in record.assets where !asset.relativePath.hasPrefix("AlbumAssets/") && !assets.contains(where: { $0.kind == asset.kind }) {
                guard let url = assetURL(asset), FileManager.default.fileExists(atPath: url.path) else { continue }
                let descriptor = MotionArtworkDescriptor(kind: asset.kind, url: asset.sourceURL, width: asset.width, height: asset.height)
                if let migrated = try importMotion(from: url, descriptor: descriptor, startTime: asset.startTime, duration: asset.duration,
                    fileExtension: url.pathExtension, albumIdentity: resolvedKey) { assets.append(migrated) }
            }
        }
        record.assets = assets
        guard !assets.isEmpty || userSelected else { record.albumMotionIdentity = nil; return record }
        if shared?.identity != resolvedKey || shared?.assets != assets {
            try writeAlbum(AlbumMotionRecord(identity: resolvedKey, catalogAlbumID: resolvedCatalogID, assets: assets,
                updatedAt: shared?.assets == assets ? shared?.updatedAt : Date(), isUserSelected: shared?.isUserSelected),
                fallback: identity.fallbackKey)
        } else {
            try writeAlias(identity.fallbackKey, to: resolvedKey, catalogID: resolvedCatalogID)
        }
        record.albumMotionIdentity = resolvedKey
        return record
    }

    func albumMotionUpdatedAt(for record: MusicEnrichmentRecord) throws -> Date? {
        guard let key = record.albumMotionIdentity ?? record.motionAlbumIdentity?.key else { return nil }
        return try albumRecord(key)?.updatedAt
    }

    func albumMotion(for record: MusicEnrichmentRecord, kind: String) throws -> StoredMotionArtwork? {
        try resolveMotion(in: record).assets.first { $0.kind == kind }
    }

    /// The album's own state, regardless of a song's individual choice.
    func albumMotionState(for record: MusicEnrichmentRecord) throws -> AlbumMotionState? {
        guard !isClosed, let identity = record.motionAlbumIdentity else { return nil }
        let (key, _, shared) = try resolvedAlbum(identity)
        return AlbumMotionState(key: key, assets: shared?.assets.filter(assetExists) ?? [], isUserSelected: shared?.isUserSelected == true)
    }

    /// Records an explicit album choice (empty assets: no motion artwork), or
    /// with `userSelected` false hands the album back to the automatic pass.
    @discardableResult
    func setAlbumMotion(_ assets: [StoredMotionArtwork], userSelected: Bool, for record: MusicEnrichmentRecord) throws -> String? {
        guard !isClosed, let identity = record.motionAlbumIdentity else { return nil }
        let (key, catalogID, _) = try resolvedAlbum(identity)
        try writeAlbum(AlbumMotionRecord(identity: key, catalogAlbumID: catalogID, assets: assets,
            updatedAt: Date(), isUserSelected: userSelected ? true : nil), fallback: identity.fallbackKey)
        return key
    }

    /// An automatic arrival never replaces an explicit album choice.
    func saveAlbumMotion(_ asset: StoredMotionArtwork, for record: MusicEnrichmentRecord) throws {
        guard !isClosed, let identity = record.motionAlbumIdentity else { return }
        let (key, catalogID, shared) = try resolvedAlbum(identity)
        guard shared?.isUserSelected != true else { return }
        var assets = shared?.assets.filter(assetExists) ?? []
        assets.removeAll { $0.kind == asset.kind }
        assets.append(asset)
        try writeAlbum(AlbumMotionRecord(identity: key, catalogAlbumID: catalogID, assets: assets, updatedAt: Date()),
            fallback: identity.fallbackKey)
    }

    func importArtwork(_ data: Data, key: String) throws {
        guard !isClosed, !data.isEmpty else { return }
        let url = artworkURL(key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Only the obsolete catalog still image is invalidated when the song
    /// identity is corrected. Track artwork and downloaded motion are untouched.
    func removeArtwork(key: String) throws {
        guard !isClosed else { return }
        let url = artworkURL(key: key)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func snapshot(_ input: MusicEnrichmentRecord) -> MusicEnrichmentSnapshot {
        let record = (try? resolveMotion(in: input)) ?? input
        func resource(_ kind: String) -> MotionArtworkResource? {
            guard let asset = record.assets.first(where: { $0.kind == kind }),
                  !asset.relativePath.hasPrefix("/"),
                  !asset.relativePath.split(separator: "/").contains("..") else { return nil }
            guard let url = assetURL(asset) else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return MotionArtworkResource(url: url, startTime: asset.startTime, duration: asset.duration)
        }
        let lyrics = record.lyricsTTML
        return MusicEnrichmentSnapshot(
            record: record, squareArtwork: resource("square"), tallArtwork: resource("tall"),
            artworkData: try? Data(contentsOf: artworkURL(key: record.query.key)),
            lyricsTTML: lyrics, lyricsIdentity: lyrics.map(Self.digest)
        )
    }

    func close() { isClosed = true }

    private func recordURL(key: String) -> URL {
        rootURL.appendingPathComponent("Records", isDirectory: true)
            .appendingPathComponent("\(Self.digest(key)).json")
    }

    private func artworkURL(key: String) -> URL {
        rootURL.appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("\(Self.digest(key))-artwork.bin")
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
