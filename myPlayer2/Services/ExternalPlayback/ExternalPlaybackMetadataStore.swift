//
//  ExternalPlaybackMetadataStore.swift
//  myPlayer2
//
//  Central resolver/cache for metadata coming from external playback sources.
//

import Foundation

@Observable
@MainActor
final class ExternalPlaybackMetadataStore {
    static let shared = ExternalPlaybackMetadataStore()

    private enum Keys {
        static let overrides = "externalPlayback.matchOverrides.v1"
        static let records = "externalPlayback.cacheRecords.v1"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let matchResolver = ExternalPlaybackMatchResolver()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var overrides: [String: ExternalPlaybackMatchOverride] = [:]
    private var records: [String: ExternalPlaybackCacheRecord] = [:]
    private var lastCacheLogAt: [String: Date] = [:]

    private init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        overrides = Self.load([String: ExternalPlaybackMatchOverride].self, from: Keys.overrides, defaults: defaults, decoder: decoder) ?? [:]
        records = Self.load([String: ExternalPlaybackCacheRecord].self, from: Keys.records, defaults: defaults, decoder: decoder) ?? [:]
    }

    func effectiveMetadata(for raw: ExternalPlaybackRawMetadata) -> ExternalPlaybackEffectiveMetadata {
        let override = overrides[raw.stableKey]
        return ExternalPlaybackEffectiveMetadata(
            title: nonEmpty(override?.title) ?? raw.title,
            artist: nonEmpty(override?.artist) ?? raw.artist,
            album: nonEmpty(override?.album) ?? raw.album,
            usesOverride: override?.isEmpty == false
        )
    }

    func override(for stableKey: String) -> ExternalPlaybackMatchOverride? {
        overrides[stableKey]
    }

    func saveOverride(_ override: ExternalPlaybackMatchOverride, for stableKey: String) {
        if override.isEmpty {
            overrides.removeValue(forKey: stableKey)
        } else {
            overrides[stableKey] = override
        }
        // Do NOT wipe records here — record validity is checked via fingerprint in resolve().
        // Wiping records would discard network artwork and auto-lyrics caches unnecessarily.
        // However, if the metadata override changed, auto-lyrics may be stale; we clear only auto-lyrics.
        if let existing = records[stableKey],
           existing.overrideFingerprint != override.fingerprint {
            updateRecord(stableKey: stableKey) { record in
                record.networkLyrics = nil
                record.lyricsSource = nil
            }
        }
        persistOverrides()
        persistRecords()
    }

    func clearOverride(for stableKey: String) {
        overrides.removeValue(forKey: stableKey)
        records.removeValue(forKey: stableKey)
        persistOverrides()
        persistRecords()
    }

    func resolve(
        raw: ExternalPlaybackRawMetadata,
        libraryTracks: [Track]
    ) async -> ExternalPlaybackResolution {
        let stableKey = raw.stableKey
        let effective = effectiveMetadata(for: raw)
        let overrideFingerprint = overrides[stableKey]?.fingerprint
        let libraryFingerprint = Self.libraryFingerprint(for: libraryTracks)

        if let cached = records[stableKey],
           cached.isCurrentVersion,
           cached.overrideFingerprint == overrideFingerprint,
           cached.libraryFingerprint == libraryFingerprint {
            let track = cached.matchResult.trackID.flatMap { id in
                libraryTracks.first { $0.id == id }
            }
            logCacheEventOnce("hit:\(stableKey)", message: "[ExternalPlayback] cache hit \(stableKey) status=\(cached.matchResult.status.rawValue) score=\(String(format: "%.2f", cached.matchResult.confidence))")
            return ExternalPlaybackResolution(
                raw: raw,
                effective: effective,
                stableKey: stableKey,
                matchedTrack: track,
                matchResult: cached.matchResult,
                cacheRecord: cached,
                cacheHit: true
            )
        }

        let candidates = libraryTracks.map {
            ExternalPlaybackTrackCandidate(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration
            )
        }
        let result = await matchResolver.bestLocalMatch(
            raw: raw,
            effective: effective,
            candidates: candidates
        )
        let matchedTrack = result.trackID.flatMap { id in
            libraryTracks.first { $0.id == id }
        }
        let now = Date()
        let record = ExternalPlaybackCacheRecord(
            version: ExternalPlaybackCacheRecord.currentVersion,
            stableKey: stableKey,
            input: raw,
            effective: effective,
            overrideFingerprint: overrideFingerprint,
            libraryFingerprint: libraryFingerprint,
            matchResult: result,
            artworkSource: records[stableKey]?.artworkSource,
            lyricsSource: records[stableKey]?.lyricsSource,
            networkArtworkFileName: records[stableKey]?.networkArtworkFileName,
            networkLyrics: records[stableKey]?.networkLyrics,
            manualLyricsFingerprint: overrides[stableKey]?.manualLyricsFingerprint,
            createdAt: records[stableKey]?.createdAt ?? now,
            updatedAt: now
        )
        records[stableKey] = record
        persistRecords()
        logCacheEventOnce("resolve:\(stableKey)", message: "[ExternalPlayback] resolved \(stableKey) status=\(result.status.rawValue) score=\(String(format: "%.2f", result.confidence)) reason=\(result.reason)")

        return ExternalPlaybackResolution(
            raw: raw,
            effective: effective,
            stableKey: stableKey,
            matchedTrack: matchedTrack,
            matchResult: result,
            cacheRecord: record,
            cacheHit: false
        )
    }

    func cachedNetworkArtwork(for stableKey: String) -> Data? {
        guard let fileName = records[stableKey]?.networkArtworkFileName else { return nil }
        return try? Data(contentsOf: artworkCacheDirectory().appendingPathComponent(fileName))
    }

    func cachedArtwork(for stableKey: String, source: String) -> Data? {
        guard records[stableKey]?.artworkSource == source else { return nil }
        return cachedNetworkArtwork(for: stableKey)
    }

    func storeNetworkArtwork(_ data: Data, for stableKey: String, source: String) {
        guard !data.isEmpty else { return }
        let fileName = "\(sanitize(stableKey))-\(ArtworkAssetStore.checksum(for: data)).img"
        let directory = artworkCacheDirectory()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        updateRecord(stableKey: stableKey) { record in
            record.networkArtworkFileName = fileName
            record.artworkSource = source
        }
    }

    // MARK: - Lyrics Cache (Manual Locked + Auto)

    /// Returns manually-selected lyrics if present and non-empty.
    func manualLyrics(for stableKey: String) -> String? {
        overrides[stableKey]?.manuallySelectedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? overrides[stableKey]?.manuallySelectedLyrics
            : nil
    }

    func saveManualLyrics(_ lyrics: String, source: String, for stableKey: String) {
        if var override = overrides[stableKey] {
            override.manuallySelectedLyrics = lyrics
            override.manuallySelectedLyricsSource = source
            override.updatedAt = Date()
            overrides[stableKey] = override
        } else {
            overrides[stableKey] = ExternalPlaybackMatchOverride(
                title: nil,
                artist: nil,
                album: nil,
                manuallySelectedLyrics: lyrics,
                manuallySelectedLyricsSource: source,
                updatedAt: Date()
            )
        }
        persistOverrides()
        // Also stamp the record so resolve() knows manual lyrics are present.
        updateRecord(stableKey: stableKey) { record in
            record.manualLyricsFingerprint = overrides[stableKey]?.manualLyricsFingerprint
        }
    }

    /// Returns auto-fetched network lyrics (excluding manual lock and empty noResult markers).
    func cachedAutoLyrics(for stableKey: String) -> String? {
        guard let record = records[stableKey] else { return nil }
        guard let lyrics = record.networkLyrics else { return nil }
        let trimmed = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // If the cached lyrics came from a manual lock that was later promoted to override,
        // treat it as manual (return nil here so the manual path takes it).
        if record.lyricsSource == "manualOverride" {
            return nil
        }
        return lyrics
    }

    func storeNetworkLyrics(_ lyrics: String, for stableKey: String, source: String) {
        // Ensure a record exists before updating (create stub if needed)
        if records[stableKey] == nil {
            let now = Date()
            records[stableKey] = ExternalPlaybackCacheRecord(
                version: ExternalPlaybackCacheRecord.currentVersion,
                stableKey: stableKey,
                input: ExternalPlaybackRawMetadata(source: .appleMusic, title: "", artist: "", duration: 0),
                effective: ExternalPlaybackEffectiveMetadata(title: "", artist: "", usesOverride: false),
                overrideFingerprint: overrides[stableKey]?.fingerprint,
                libraryFingerprint: "",
                matchResult: ExternalPlaybackMatchResult(status: .noResult, trackID: nil, confidence: 0, reason: "stub"),
                artworkSource: nil,
                lyricsSource: nil,
                networkArtworkFileName: nil,
                networkLyrics: nil,
                manualLyricsFingerprint: overrides[stableKey]?.manualLyricsFingerprint,
                createdAt: now,
                updatedAt: now
            )
        }
        updateRecord(stableKey: stableKey) { record in
            record.networkLyrics = lyrics
            record.lyricsSource = source
        }
    }

    func clearAutoLyricsCache(for stableKey: String) {
        updateRecord(stableKey: stableKey) { record in
            record.networkLyrics = nil
            record.lyricsSource = nil
        }
    }

    func updateArtworkSource(_ source: String, for stableKey: String) {
        updateRecord(stableKey: stableKey) { record in
            record.artworkSource = source
        }
    }

    func updateLyricsSource(_ source: String, for stableKey: String) {
        updateRecord(stableKey: stableKey) { record in
            record.lyricsSource = source
        }
    }

    func clearAllCaches() async {
        overrides.removeAll()
        records.removeAll()
        persistOverrides()
        persistRecords()
        let directory = artworkCacheDirectory()
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }

    private func updateRecord(stableKey: String, mutate: (inout ExternalPlaybackCacheRecord) -> Void) {
        guard var record = records[stableKey] else { return }
        mutate(&record)
        record.updatedAt = Date()
        records[stableKey] = record
        persistRecords()
    }

    private func persistOverrides() {
        persist(overrides, key: Keys.overrides)
    }

    private func persistRecords() {
        persist(records, key: Keys.records)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(
        _ type: T.Type,
        from key: String,
        defaults: UserDefaults,
        decoder: JSONDecoder
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private static func libraryFingerprint(for tracks: [Track]) -> String {
        let count = tracks.count
        let checksum = tracks.prefix(64).reduce(UInt64(count)) { partial, track in
            partial ^ UInt64(bitPattern: Int64(track.id.uuidString.hashValue))
                ^ UInt64(ArtworkAssetStore.checksum(for: track.loadArtworkDataIfNeeded()))
                ^ UInt64((track.loadLyricsIfNeeded()?.count ?? 0) + (track.loadTTMLLyricsIfNeeded()?.count ?? 0))
        }
        return "\(count)-\(checksum)"
    }

    private func artworkCacheDirectory() -> URL {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root
            .appendingPathComponent("kmgccc_player", isDirectory: true)
            .appendingPathComponent("ExternalPlaybackArtwork", isDirectory: true)
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func logCacheEventOnce(_ key: String, message: String) {
        let now = Date()
        if let last = lastCacheLogAt[key], now.timeIntervalSince(last) < 30 {
            return
        }
        lastCacheLogAt[key] = now
        Log.info(message, category: .playback)
    }
}

actor ExternalPlaybackMatchResolver {
    func bestLocalMatch(
        raw: ExternalPlaybackRawMetadata,
        effective: ExternalPlaybackEffectiveMetadata,
        candidates: [ExternalPlaybackTrackCandidate]
    ) -> ExternalPlaybackMatchResult {
        let sourceTitle = ExternalPlaybackTextNormalizer.normalize(effective.title)
        let sourceArtist = ExternalPlaybackTextNormalizer.normalizeArtist(effective.artist)
        let sourceAlbum = ExternalPlaybackTextNormalizer.normalize(effective.album)

        var best: (candidate: ExternalPlaybackTrackCandidate, score: Double, reason: String)?

        for candidate in candidates {
            let title = ExternalPlaybackTextNormalizer.normalize(candidate.title)
            let titleScore = ExternalPlaybackTextNormalizer.stringSimilarity(sourceTitle, title)
            guard titleScore >= 0.50 || title.compact.contains(sourceTitle.compact) || sourceTitle.compact.contains(title.compact) else {
                continue
            }

            let artist = ExternalPlaybackTextNormalizer.normalizeArtist(candidate.artist)
            let artistScore = ExternalPlaybackTextNormalizer.artistSimilarity(sourceArtist, artist)
            guard artistScore >= 0.22 else { continue }

            if ExternalPlaybackTextNormalizer.hasObviousConflict(
                titleScore: titleScore,
                artistScore: artistScore,
                sourceDuration: raw.duration,
                candidateDuration: candidate.duration
            ) {
                continue
            }

            let album = ExternalPlaybackTextNormalizer.normalize(candidate.album)
            let albumScore = sourceAlbum.compact.isEmpty || album.compact.isEmpty
                ? 0.5
                : ExternalPlaybackTextNormalizer.stringSimilarity(sourceAlbum, album)
            let durationScore = ExternalPlaybackTextNormalizer.durationScore(
                source: raw.duration,
                candidate: candidate.duration
            )

            let score = titleScore * 0.46 + artistScore * 0.28 + durationScore * 0.18 + albumScore * 0.08
            let reason = "title=\(String(format: "%.2f", titleScore)) artist=\(String(format: "%.2f", artistScore)) duration=\(String(format: "%.2f", durationScore)) album=\(String(format: "%.2f", albumScore))"
            if best == nil || score > best!.score {
                best = (candidate, score, reason)
            }
        }

        guard let best else {
            return ExternalPlaybackMatchResult(
                status: .noResult,
                trackID: nil,
                confidence: 0,
                reason: "no candidate passed prefilter"
            )
        }

        guard best.score >= 0.72 else {
            return ExternalPlaybackMatchResult(
                status: .lowConfidenceRejected,
                trackID: nil,
                confidence: best.score,
                reason: best.reason
            )
        }

        return ExternalPlaybackMatchResult(
            status: .matched,
            trackID: best.candidate.id,
            confidence: best.score,
            reason: best.reason
        )
    }
}
