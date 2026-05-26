//
//  LibrarySearchIndex.swift
//  myPlayer2
//
//  Persistent SQLite FTS5 + n-gram search index for local library metadata
//  and parsed lyric text.
//

import CryptoKit
import Foundation
import SQLite3

private nonisolated let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor LibrarySearchIndex {
    static let shared = LibrarySearchIndex()

    private var db: OpaquePointer?
    private var rebuildTask: Task<Void, Never>?
    private var schemaReady = false

    private init() {}

    func scheduleFullRebuild(from sources: [SearchDocumentSource], reason: String) {
        rebuildTask?.cancel()
        rebuildTask = Task(priority: .utility) { [sources] in
            await self.replaceAllDocuments(sources, reason: reason)
        }
    }

    func replaceAllDocuments(_ sources: [SearchDocumentSource], reason: String) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try ensureSchema()
            try execute("BEGIN IMMEDIATE TRANSACTION")
            try execute("DELETE FROM documents")
            try execute("DELETE FROM search_fts")
            try execute("DELETE FROM grams")

            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let document = try makeDocument(from: source, reusable: nil)
                try store(document)
                if (index + 1).isMultiple(of: 50) {
                    await Task.yield()
                }
            }

            try execute("COMMIT")
            Log.info(
                "[SearchIndex] rebuild complete reason=\(reason) tracks=\(sources.count) ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000))",
                category: .library
            )
        } catch is CancellationError {
            try? execute("ROLLBACK")
            Log.info("[SearchIndex] rebuild cancelled reason=\(reason)", category: .library)
        } catch {
            try? execute("ROLLBACK")
            Log.error("[SearchIndex] rebuild failed reason=\(reason): \(error)", category: .library)
        }
    }

    func upsertDocuments(_ sources: [SearchDocumentSource], reason: String) async {
        guard !sources.isEmpty else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try ensureSchema()
            try execute("BEGIN IMMEDIATE TRANSACTION")

            for source in sources {
                let reusable = try existingDocument(trackID: source.trackID)
                let document = try makeDocument(from: source, reusable: reusable)
                try store(document)
            }

            try execute("COMMIT")
            Log.info(
                "[SearchIndex] upsert complete reason=\(reason) tracks=\(sources.count) ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000))",
                category: .library
            )
        } catch {
            try? execute("ROLLBACK")
            Log.error("[SearchIndex] upsert failed reason=\(reason): \(error)", category: .library)
        }
    }

    func deleteTrackIDs(_ trackIDs: [UUID], reason: String) async {
        let uniqueIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueIDs.isEmpty else { return }

        do {
            try ensureSchema()
            try execute("BEGIN IMMEDIATE TRANSACTION")
            for trackID in uniqueIDs {
                try deleteDocument(trackID: trackID.uuidString)
            }
            try execute("COMMIT")
            Log.info(
                "[SearchIndex] delete complete reason=\(reason) tracks=\(uniqueIDs.count)",
                category: .library
            )
        } catch {
            try? execute("ROLLBACK")
            Log.error("[SearchIndex] delete failed reason=\(reason): \(error)", category: .library)
        }
    }

    func removeStoreFiles() async {
        rebuildTask?.cancel()
        if let db {
            sqlite3_close(db)
            self.db = nil
            schemaReady = false
        }
        for url in SearchIndexStorePaths.relatedStoreFiles where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func search(query rawQuery: String, scopedTo allowedTrackIDs: Set<UUID>? = nil, limit: Int = 200) async -> [LibrarySearchHit] {
        let query = SearchQuery(rawValue: rawQuery)
        guard !query.normalized.isEmpty else { return [] }

        do {
            try ensureSchema()

            var candidateScores: [String: Double] = [:]
            let retrievalLimit = max(300, min(4_000, limit * 12))
            try retrieveFTSCandidates(query: query, limit: retrievalLimit, into: &candidateScores)
            try retrieveNgramCandidates(query: query, limit: retrievalLimit, into: &candidateScores)

            let allowedStrings = allowedTrackIDs.map { Set($0.map(\.uuidString)) }
            let candidateIDs = candidateScores.keys.filter { id in
                allowedStrings?.contains(id) ?? true
            }
            guard !candidateIDs.isEmpty else { return [] }

            let documents = try fetchDocuments(trackIDs: Array(candidateIDs))
            let ranked = documents.compactMap { document -> LibrarySearchHit? in
                let baseScore = candidateScores[document.trackID.uuidString] ?? 0
                let ranking = rank(document: document, query: query, baseScore: baseScore)
                guard ranking.score > minimumScore(for: query) else { return nil }
                return LibrarySearchHit(
                    trackID: document.trackID,
                    score: ranking.score,
                    lyricSnippetLine: ranking.lyricSnippet?.line,
                    lyricHighlightRanges: ranking.lyricSnippet?.highlightRanges ?? [],
                    matchedLyrics: ranking.matchedLyrics
                )
            }
            .sorted {
                if abs($0.score - $1.score) > 0.000_1 {
                    return $0.score > $1.score
                }
                return $0.trackID.uuidString < $1.trackID.uuidString
            }

            return Array(ranked.prefix(limit))
        } catch {
            Log.error("[SearchIndex] search failed query='\(rawQuery)': \(error)", category: .library)
            return []
        }
    }

    // MARK: - Schema

    private func ensureSchema() throws {
        _ = try database()
        guard !schemaReady else { return }

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA temp_store=MEMORY")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS documents (
                track_id TEXT PRIMARY KEY NOT NULL,
                title_raw TEXT NOT NULL,
                title_norm TEXT NOT NULL,
                artist_raw TEXT NOT NULL,
                artist_norm TEXT NOT NULL,
                album_raw TEXT NOT NULL,
                album_norm TEXT NOT NULL,
                combined_norm TEXT NOT NULL,
                lyrics_raw TEXT NOT NULL,
                lyrics_norm TEXT NOT NULL,
                lyrics_path TEXT,
                lyrics_mtime REAL,
                lyrics_size INTEGER,
                lyrics_hash TEXT,
                play_count INTEGER NOT NULL DEFAULT 0,
                preference_score REAL NOT NULL DEFAULT 0,
                last_played_at REAL,
                updated_at REAL NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
                track_id UNINDEXED,
                title,
                artist,
                album,
                combined,
                lyrics,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS grams (
                track_id TEXT NOT NULL,
                field TEXT NOT NULL,
                gram TEXT NOT NULL,
                weight REAL NOT NULL,
                PRIMARY KEY (track_id, field, gram)
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_search_grams_gram ON grams(gram)")
        try execute("CREATE INDEX IF NOT EXISTS idx_search_grams_track ON grams(track_id)")

        schemaReady = true
    }

    private func database() throws -> OpaquePointer {
        if let db { return db }

        let url = SearchIndexStorePaths.storeURL
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SearchIndexError.sqlite(message)
        }
        db = opened
        return opened
    }

    // MARK: - Upsert

    private func makeDocument(
        from source: SearchDocumentSource,
        reusable existing: SearchIndexedDocument?
    ) throws -> SearchIndexedDocument {
        let titleNormalized = LibrarySearchTextNormalizer.normalize(source.titleRaw)
        let artistNormalized = LibrarySearchTextNormalizer.normalize(source.artistRaw)
        let albumNormalized = LibrarySearchTextNormalizer.normalize(source.albumRaw)
        let combinedRaw = [
            source.titleRaw,
            source.artistRaw,
            source.albumArtistRaw ?? "",
            source.albumRaw
        ].filter { !$0.isEmpty }.joined(separator: " ")
        let combinedNormalized = LibrarySearchTextNormalizer.normalize(combinedRaw)
        let lyrics = try resolveLyrics(for: source, reusable: existing)

        return SearchIndexedDocument(
            trackID: source.trackID,
            titleRaw: source.titleRaw,
            titleNormalized: titleNormalized,
            artistRaw: source.artistRaw,
            artistNormalized: artistNormalized,
            albumRaw: source.albumRaw,
            albumNormalized: albumNormalized,
            titleArtistCombinedNormalized: combinedNormalized,
            lyricsPlainTextRaw: lyrics.raw,
            lyricsPlainTextNormalized: LibrarySearchTextNormalizer.normalize(lyrics.raw),
            lyricsFilePath: lyrics.path,
            lyricsFileModifiedAt: lyrics.modifiedAt,
            lyricsFileSize: lyrics.fileSize,
            lyricsHash: lyrics.hash,
            playCount: source.playCount,
            preferenceScore: source.preferenceScore,
            lastPlayedAt: source.lastPlayedAt,
            updatedAt: source.updatedAt
        )
    }

    private func store(_ document: SearchIndexedDocument) throws {
        try deleteDocument(trackID: document.trackID.uuidString)
        try insertDocument(document)
        try insertFTS(document)
        try insertGrams(document)
    }

    private func insertDocument(_ document: SearchIndexedDocument) throws {
        let sql =
            """
            INSERT INTO documents (
                track_id, title_raw, title_norm, artist_raw, artist_norm,
                album_raw, album_norm, combined_norm, lyrics_raw, lyrics_norm,
                lyrics_path, lyrics_mtime, lyrics_size, lyrics_hash,
                play_count, preference_score, last_played_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindText(document.trackID.uuidString, to: statement, at: 1)
        bindText(document.titleRaw, to: statement, at: 2)
        bindText(document.titleNormalized, to: statement, at: 3)
        bindText(document.artistRaw, to: statement, at: 4)
        bindText(document.artistNormalized, to: statement, at: 5)
        bindText(document.albumRaw, to: statement, at: 6)
        bindText(document.albumNormalized, to: statement, at: 7)
        bindText(document.titleArtistCombinedNormalized, to: statement, at: 8)
        bindText(document.lyricsPlainTextRaw, to: statement, at: 9)
        bindText(document.lyricsPlainTextNormalized, to: statement, at: 10)
        bindOptionalText(document.lyricsFilePath, to: statement, at: 11)
        bindOptionalDouble(document.lyricsFileModifiedAt, to: statement, at: 12)
        bindOptionalInt64(document.lyricsFileSize, to: statement, at: 13)
        bindOptionalText(document.lyricsHash, to: statement, at: 14)
        sqlite3_bind_int(statement, 15, Int32(document.playCount))
        sqlite3_bind_double(statement, 16, document.preferenceScore)
        bindOptionalDouble(document.lastPlayedAt?.timeIntervalSince1970, to: statement, at: 17)
        sqlite3_bind_double(statement, 18, document.updatedAt.timeIntervalSince1970)

        try stepDone(statement)
    }

    private func insertFTS(_ document: SearchIndexedDocument) throws {
        let statement = try prepare(
            """
            INSERT INTO search_fts (track_id, title, artist, album, combined, lyrics)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(document.trackID.uuidString, to: statement, at: 1)
        bindText(document.titleNormalized, to: statement, at: 2)
        bindText(document.artistNormalized, to: statement, at: 3)
        bindText(document.albumNormalized, to: statement, at: 4)
        bindText(document.titleArtistCombinedNormalized, to: statement, at: 5)
        bindText(document.lyricsPlainTextNormalized, to: statement, at: 6)
        try stepDone(statement)
    }

    private func insertGrams(_ document: SearchIndexedDocument) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO grams (track_id, field, gram, weight) VALUES (?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        func insert(field: String, text: String, weight: Double, limit: Int? = nil) throws {
            let grams = LibrarySearchTextNormalizer.characterNgrams(
                text,
                minimum: 1,
                maximum: 3,
                limit: limit
            )
            for gram in grams {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindText(document.trackID.uuidString, to: statement, at: 1)
                bindText(field, to: statement, at: 2)
                bindText(gram, to: statement, at: 3)
                sqlite3_bind_double(statement, 4, weight)
                try stepDone(statement)
            }
        }

        try insert(field: "title", text: document.titleNormalized, weight: 12)
        try insert(field: "artist", text: document.artistNormalized, weight: 8)
        try insert(field: "album", text: document.albumNormalized, weight: 4)
        try insert(field: "combined", text: document.titleArtistCombinedNormalized, weight: 10)
        if !document.lyricsPlainTextNormalized.isEmpty {
            try insert(field: "lyrics", text: document.lyricsPlainTextNormalized, weight: 1, limit: 6_000)
        }
    }

    private func deleteDocument(trackID: String) throws {
        try executeBound("DELETE FROM documents WHERE track_id = ?", values: [trackID])
        try executeBound("DELETE FROM search_fts WHERE track_id = ?", values: [trackID])
        try executeBound("DELETE FROM grams WHERE track_id = ?", values: [trackID])
    }

    // MARK: - Lyrics

    private struct LyricsPayload {
        let raw: String
        let path: String?
        let modifiedAt: Double?
        let fileSize: Int64?
        let hash: String?
    }

    private func resolveLyrics(
        for source: SearchDocumentSource,
        reusable existing: SearchIndexedDocument?
    ) throws -> LyricsPayload {
        if let inlineTTML = source.inlineTTMLText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inlineTTML.isEmpty {
            let data = Data(inlineTTML.utf8)
            let raw = TTMLPlainTextExtractor.extractPlainText(from: inlineTTML, sourceDescription: source.trackID.uuidString)
            return LyricsPayload(raw: raw, path: nil, modifiedAt: nil, fileSize: Int64(data.count), hash: Self.sha256Hex(data))
        }

        if let inlinePlain = source.inlinePlainLyricsText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inlinePlain.isEmpty {
            let data = Data(inlinePlain.utf8)
            return LyricsPayload(
                raw: TTMLPlainTextExtractor.normalizeExtractedText(inlinePlain),
                path: nil,
                modifiedAt: nil,
                fileSize: Int64(data.count),
                hash: Self.sha256Hex(data)
            )
        }

        if let url = source.ttmlLyricsFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            return try resolveDiskLyrics(
                url: url,
                isTTML: true,
                trackID: source.trackID,
                reusable: existing
            )
        }

        if let url = source.plainLyricsFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            return try resolveDiskLyrics(
                url: url,
                isTTML: url.pathExtension.lowercased() == "ttml",
                trackID: source.trackID,
                reusable: existing
            )
        }

        return LyricsPayload(raw: "", path: nil, modifiedAt: nil, fileSize: nil, hash: nil)
    }

    private func resolveDiskLyrics(
        url: URL,
        isTTML: Bool,
        trackID: UUID,
        reusable existing: SearchIndexedDocument?
    ) throws -> LyricsPayload {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value

        if let existing,
           existing.lyricsFilePath == url.path,
           existing.lyricsFileModifiedAt == modifiedAt,
           existing.lyricsFileSize == fileSize {
            return LyricsPayload(
                raw: existing.lyricsPlainTextRaw,
                path: existing.lyricsFilePath,
                modifiedAt: existing.lyricsFileModifiedAt,
                fileSize: existing.lyricsFileSize,
                hash: existing.lyricsHash
            )
        }

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let raw = isTTML
            ? TTMLPlainTextExtractor.extractPlainText(from: text, sourceDescription: "\(trackID.uuidString):\(url.lastPathComponent)")
            : TTMLPlainTextExtractor.normalizeExtractedText(text)

        return LyricsPayload(
            raw: raw,
            path: url.path,
            modifiedAt: modifiedAt,
            fileSize: fileSize,
            hash: Self.sha256Hex(data)
        )
    }

    // MARK: - Candidate Retrieval

    private func retrieveFTSCandidates(
        query: SearchQuery,
        limit: Int,
        into candidateScores: inout [String: Double]
    ) throws {
        let expression = makeFTSExpression(query: query)
        guard !expression.isEmpty else { return }

        let statement = try prepare(
            "SELECT track_id FROM search_fts WHERE search_fts MATCH ? LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }

        bindText(expression, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, 0) else { continue }
            candidateScores[id, default: 0] += 40
        }
    }

    private func retrieveNgramCandidates(
        query: SearchQuery,
        limit: Int,
        into candidateScores: inout [String: Double]
    ) throws {
        let grams = LibrarySearchTextNormalizer.queryNgrams(query.normalized)
        guard !grams.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: grams.count).joined(separator: ",")
        let skipLyrics = query.compact.count < 2
        let fieldClause = skipLyrics ? " AND field != 'lyrics'" : ""
        let sql =
            """
            SELECT track_id, SUM(weight) AS score, COUNT(*) AS hits
            FROM grams
            WHERE gram IN (\(placeholders))\(fieldClause)
            GROUP BY track_id
            ORDER BY score DESC, hits DESC
            LIMIT ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        for (index, gram) in grams.enumerated() {
            bindText(gram, to: statement, at: Int32(index + 1))
        }
        sqlite3_bind_int(statement, Int32(grams.count + 1), Int32(limit))

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, 0) else { continue }
            let score = sqlite3_column_double(statement, 1)
            let hits = sqlite3_column_double(statement, 2)
            let coverage = min(1.0, hits / Double(max(grams.count, 1)))
            candidateScores[id, default: 0] += score * (0.55 + coverage)
        }
    }

    private func makeFTSExpression(query: SearchQuery) -> String {
        let tokens = query.tokens.isEmpty ? [query.normalized] : query.tokens
        return tokens
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { token in
                let sanitized = token.filter { $0.isLetter || $0.isNumber || !$0.isASCII }
                return sanitized.isEmpty ? "" : "\(sanitized)*"
            }
            .filter { !$0.isEmpty }
            .joined(separator: " OR ")
    }

    // MARK: - Ranking

    private struct SearchQuery {
        let rawValue: String
        let normalized: String
        let compact: String
        let tokens: [String]

        init(rawValue: String) {
            self.rawValue = rawValue
            normalized = LibrarySearchTextNormalizer.normalize(rawValue)
            compact = LibrarySearchTextNormalizer.compact(rawValue)
            tokens = LibrarySearchTextNormalizer.tokens(rawValue)
        }
    }

    private struct RankingResult {
        let score: Double
        let lyricSnippet: LyricSnippetResult?
        let matchedLyrics: Bool
    }

    private struct LyricSnippetResult {
        let line: String
        let highlightRanges: [SearchHighlightRange]
    }

    private func rank(
        document: SearchIndexedDocument,
        query: SearchQuery,
        baseScore: Double
    ) -> RankingResult {
        let titleCompact = LibrarySearchTextNormalizer.compact(document.titleNormalized)
        let artistCompact = LibrarySearchTextNormalizer.compact(document.artistNormalized)
        let albumCompact = LibrarySearchTextNormalizer.compact(document.albumNormalized)
        let combinedCompact = LibrarySearchTextNormalizer.compact(document.titleArtistCombinedNormalized)
        let lyricsCompact = LibrarySearchTextNormalizer.compact(document.lyricsPlainTextNormalized)

        var score = baseScore
        score += fieldScore(
            normalized: document.titleNormalized,
            compact: titleCompact,
            query: query,
            exact: 1_000,
            prefix: 760,
            contains: 460,
            fuzzy: 240
        )
        score += fieldScore(
            normalized: document.artistNormalized,
            compact: artistCompact,
            query: query,
            exact: 420,
            prefix: 320,
            contains: 220,
            fuzzy: 140
        )
        score += fieldScore(
            normalized: document.albumNormalized,
            compact: albumCompact,
            query: query,
            exact: 220,
            prefix: 160,
            contains: 110,
            fuzzy: 70
        )

        if combinedCompact.contains(query.compact), query.compact.count >= 2 {
            score += 360
        }
        score += titleArtistCombinationScore(
            titleCompact: titleCompact,
            artistCompact: artistCompact,
            combinedCompact: combinedCompact,
            query: query
        )

        let lyricsScore = lyricScore(
            lyricsNormalized: document.lyricsPlainTextNormalized,
            lyricsCompact: lyricsCompact,
            query: query
        )
        score += lyricsScore

        score += min(16, log(Double(max(document.playCount, 0)) + 1) * 3)
        score += max(-8, min(8, document.preferenceScore * 2))
        if let lastPlayedAt = document.lastPlayedAt {
            let days = max(0, Date().timeIntervalSince(lastPlayedAt) / 86_400)
            score += max(0, 5 - min(5, days / 14))
        }

        let lyricSnippet = lyricsScore > 0
            ? lyricSnippet(in: document.lyricsPlainTextRaw, query: query)
            : nil

        return RankingResult(
            score: score,
            lyricSnippet: lyricSnippet,
            matchedLyrics: lyricSnippet != nil
        )
    }

    private func fieldScore(
        normalized: String,
        compact: String,
        query: SearchQuery,
        exact: Double,
        prefix: Double,
        contains: Double,
        fuzzy: Double
    ) -> Double {
        guard !query.compact.isEmpty, !compact.isEmpty else { return 0 }

        if normalized == query.normalized || compact == query.compact {
            return exact
        }
        if normalized.hasPrefix(query.normalized) || compact.hasPrefix(query.compact) {
            return prefix
        }
        if normalized.contains(query.normalized) || compact.contains(query.compact) {
            return contains
        }

        var score = 0.0
        if !query.tokens.isEmpty {
            let hits = query.tokens.filter { normalized.contains($0) || compact.contains($0) }.count
            if hits > 0 {
                score += contains * 0.45 * Double(hits) / Double(query.tokens.count)
            }
        }

        if query.compact.count >= 3 {
            let similarity = trigramSimilarity(query.compact, compact)
            if similarity >= 0.42 {
                score += fuzzy * similarity
            }
        }

        if query.compact.count >= 3,
           query.compact.count <= 32,
           compact.count <= 64 {
            let threshold = editDistanceThreshold(for: query.compact.count)
            if let distance = boundedEditDistance(query.compact, compact, maxDistance: threshold) {
                let similarity = 1.0 - Double(distance) / Double(max(query.compact.count, compact.count))
                score += fuzzy * max(0, similarity)
            }
        }

        return score
    }

    private func titleArtistCombinationScore(
        titleCompact: String,
        artistCompact: String,
        combinedCompact: String,
        query: SearchQuery
    ) -> Double {
        guard !query.compact.isEmpty else { return 0 }
        var score = 0.0

        if query.tokens.count >= 2 {
            let titleHits = query.tokens.filter { titleCompact.contains($0) }.count
            let artistHits = query.tokens.filter { artistCompact.contains($0) }.count
            if titleHits > 0, artistHits > 0 {
                score += 340
            }
            let totalHits = titleHits + artistHits
            score += 160 * Double(totalHits) / Double(query.tokens.count)
        }

        if query.compact.count >= 2 {
            for split in 1..<query.compact.count {
                let left = prefix(query.compact, count: split)
                let right = suffix(query.compact, count: query.compact.count - split)
                if (titleCompact.hasPrefix(left) && artistCompact.hasPrefix(right))
                    || (artistCompact.hasPrefix(left) && titleCompact.hasPrefix(right)) {
                    score += 300
                    break
                }
            }
        }

        if trigramSimilarity(query.compact, combinedCompact) >= 0.52 {
            score += 130
        }

        return score
    }

    private func lyricScore(
        lyricsNormalized: String,
        lyricsCompact: String,
        query: SearchQuery
    ) -> Double {
        guard !lyricsCompact.isEmpty, !query.compact.isEmpty else { return 0 }
        if query.compact.count == 1 {
            return 0
        }

        var score = 0.0
        if lyricsNormalized.contains(query.normalized) || lyricsCompact.contains(query.compact) {
            score += 115
        }

        if !query.tokens.isEmpty {
            let hits = query.tokens.filter { token in
                token.count > 1 && (lyricsNormalized.contains(token) || lyricsCompact.contains(token))
            }.count
            if hits > 0 {
                score += 55 * Double(hits) / Double(query.tokens.count)
            }
        }

        return score
    }

    private func lyricSnippet(in rawLyrics: String, query: SearchQuery) -> LyricSnippetResult? {
        guard !rawLyrics.isEmpty, query.compact.count > 1 else { return nil }
        let lines = rawLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var bestResult: LyricSnippetResult?
        var bestScore = 0.0

        for line in lines {
            let result = lyricSnippetResult(for: line, query: query)
            guard let result else { continue }
            let score = lyricLineScore(line: line, result: result, query: query)
            if score > bestScore {
                bestScore = score
                bestResult = result
            }
        }

        return bestResult
    }

    private func lyricSnippetResult(for line: String, query: SearchQuery) -> LyricSnippetResult? {
        let mapped = LibrarySearchTextNormalizer.mappedNormalize(line)
        guard !mapped.compact.isEmpty else { return nil }

        var ranges: [SearchHighlightRange] = []

        if !query.normalized.isEmpty {
            ranges.append(contentsOf: originalRanges(
                needle: query.normalized,
                haystack: mapped.normalized,
                offsets: mapped.normalizedCharacterOffsets
            ))
        }
        if !query.compact.isEmpty {
            ranges.append(contentsOf: originalRanges(
                needle: query.compact,
                haystack: mapped.compact,
                offsets: mapped.compactCharacterOffsets
            ))
        }
        for token in query.tokens where token.count > 1 {
            ranges.append(contentsOf: originalRanges(
                needle: token,
                haystack: mapped.normalized,
                offsets: mapped.normalizedCharacterOffsets
            ))
            let compactToken = LibrarySearchTextNormalizer.compact(token)
            if compactToken != token {
                ranges.append(contentsOf: originalRanges(
                    needle: compactToken,
                    haystack: mapped.compact,
                    offsets: mapped.compactCharacterOffsets
                ))
            }
        }

        let merged = mergeHighlightRanges(ranges)
        guard !merged.isEmpty else { return nil }
        return LyricSnippetResult(line: line, highlightRanges: merged)
    }

    private func originalRanges(
        needle: String,
        haystack: String,
        offsets: [Int]
    ) -> [SearchHighlightRange] {
        let needleCharacters = Array(needle)
        let haystackCharacters = Array(haystack)
        guard !needleCharacters.isEmpty,
              needleCharacters.count <= haystackCharacters.count,
              offsets.count == haystackCharacters.count
        else { return [] }

        var ranges: [SearchHighlightRange] = []
        let lastStart = haystackCharacters.count - needleCharacters.count
        for start in 0...lastStart {
            let end = start + needleCharacters.count
            guard Array(haystackCharacters[start..<end]) == needleCharacters else { continue }
            let originalStart = offsets[start]
            let originalEnd = (start..<end).reduce(originalStart) { partial, index in
                max(partial, offsets[index])
            }
            ranges.append(SearchHighlightRange(location: originalStart, length: originalEnd - originalStart + 1))
        }
        return ranges
    }

    private func mergeHighlightRanges(_ ranges: [SearchHighlightRange]) -> [SearchHighlightRange] {
        let sorted = ranges
            .filter { $0.length > 0 }
            .sorted {
                if $0.location == $1.location {
                    return $0.length > $1.length
                }
                return $0.location < $1.location
            }
        guard var current = sorted.first else { return [] }
        var merged: [SearchHighlightRange] = []

        for range in sorted.dropFirst() {
            let currentEnd = current.location + current.length
            let rangeEnd = range.location + range.length
            if range.location <= currentEnd {
                current = SearchHighlightRange(
                    location: current.location,
                    length: max(currentEnd, rangeEnd) - current.location
                )
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    private func lyricLineScore(line: String, result: LyricSnippetResult, query: SearchQuery) -> Double {
        let normalized = LibrarySearchTextNormalizer.normalize(line)
        let compact = LibrarySearchTextNormalizer.compact(normalized)
        var score = Double(result.highlightRanges.reduce(0) { $0 + $1.length })
        if normalized.contains(query.normalized) {
            score += 120
        }
        if compact.contains(query.compact) {
            score += 90
        }
        let tokenHits = query.tokens.filter { $0.count > 1 && normalized.contains($0) }.count
        score += Double(tokenHits) * 18
        score -= min(30, Double(line.count) * 0.08)
        return score
    }

    private func minimumScore(for query: SearchQuery) -> Double {
        query.compact.count <= 1 ? 120 : 55
    }

    // MARK: - Document Fetch

    private func existingDocument(trackID: UUID) throws -> SearchIndexedDocument? {
        try fetchDocuments(trackIDs: [trackID.uuidString]).first
    }

    private func fetchDocuments(trackIDs: [String]) throws -> [SearchIndexedDocument] {
        guard !trackIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ",")
        let statement = try prepare(
            """
            SELECT track_id, title_raw, title_norm, artist_raw, artist_norm,
                   album_raw, album_norm, combined_norm, lyrics_raw, lyrics_norm,
                   lyrics_path, lyrics_mtime, lyrics_size, lyrics_hash,
                   play_count, preference_score, last_played_at, updated_at
            FROM documents
            WHERE track_id IN (\(placeholders))
            """
        )
        defer { sqlite3_finalize(statement) }

        for (index, id) in trackIDs.enumerated() {
            bindText(id, to: statement, at: Int32(index + 1))
        }

        var documents: [SearchIndexedDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, 0),
                  let trackID = UUID(uuidString: idText)
            else { continue }

            documents.append(
                SearchIndexedDocument(
                    trackID: trackID,
                    titleRaw: columnText(statement, 1) ?? "",
                    titleNormalized: columnText(statement, 2) ?? "",
                    artistRaw: columnText(statement, 3) ?? "",
                    artistNormalized: columnText(statement, 4) ?? "",
                    albumRaw: columnText(statement, 5) ?? "",
                    albumNormalized: columnText(statement, 6) ?? "",
                    titleArtistCombinedNormalized: columnText(statement, 7) ?? "",
                    lyricsPlainTextRaw: columnText(statement, 8) ?? "",
                    lyricsPlainTextNormalized: columnText(statement, 9) ?? "",
                    lyricsFilePath: columnText(statement, 10),
                    lyricsFileModifiedAt: optionalDouble(statement, 11),
                    lyricsFileSize: optionalInt64(statement, 12),
                    lyricsHash: columnText(statement, 13),
                    playCount: Int(sqlite3_column_int(statement, 14)),
                    preferenceScore: sqlite3_column_double(statement, 15),
                    lastPlayedAt: optionalDouble(statement, 16).map(Date.init(timeIntervalSince1970:)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))
                )
            )
        }
        return documents
    }

    // MARK: - SQLite Helpers

    private func execute(_ sql: String) throws {
        let db = try database()
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw SearchIndexError.sqlite(message)
        }
    }

    private func executeBound(_ sql: String, values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            bindText(value, to: statement, at: Int32(index + 1))
        }
        try stepDone(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let db = try database()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SearchIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            let db = try database()
            throw SearchIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: statement, at: index)
    }

    private func bindOptionalDouble(_ value: Double?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bindOptionalInt64(_ value: Int64?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: value)
    }

    private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    // MARK: - Similarity Helpers

    private func trigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsGrams = Set(LibrarySearchTextNormalizer.characterNgrams(lhs, minimum: 2, maximum: 3))
        let rhsGrams = Set(LibrarySearchTextNormalizer.characterNgrams(rhs, minimum: 2, maximum: 3))
        guard !lhsGrams.isEmpty, !rhsGrams.isEmpty else { return 0 }
        let intersection = lhsGrams.intersection(rhsGrams).count
        return Double(2 * intersection) / Double(lhsGrams.count + rhsGrams.count)
    }

    private func boundedEditDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int? {
        let a = Array(lhs)
        let b = Array(rhs)
        guard abs(a.count - b.count) <= maxDistance else { return nil }
        if a.isEmpty { return b.count <= maxDistance ? b.count : nil }
        if b.isEmpty { return a.count <= maxDistance ? a.count : nil }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > maxDistance {
                return nil
            }
            swap(&previous, &current)
        }

        let distance = previous[b.count]
        return distance <= maxDistance ? distance : nil
    }

    private func editDistanceThreshold(for count: Int) -> Int {
        if count <= 4 { return 1 }
        if count <= 8 { return 2 }
        return 3
    }

    private func prefix(_ value: String, count: Int) -> String {
        String(value.prefix(count))
    }

    private func suffix(_ value: String, count: Int) -> String {
        String(value.suffix(count))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum SearchIndexError: Error, CustomStringConvertible {
    case sqlite(String)

    var description: String {
        switch self {
        case .sqlite(let message):
            return message
        }
    }
}
