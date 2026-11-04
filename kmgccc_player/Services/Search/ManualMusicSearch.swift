import Foundation

/// Query expansion and ranking for searches where the user chooses a result.
/// Automatic enrichment keeps its own, stricter matching rules.
nonisolated enum ManualMusicSearch {
    struct Query: Hashable, Sendable {
        let title: String
        let artist: String
        let album: String
    }

    struct Rank: Equatable, Sendable {
        let exactTitle: Bool
        let exactAlbum: Bool
        let titleSimilarity: Double
        let artistSimilarity: Double
        let albumSimilarity: Double

        func isBetter(than other: Rank) -> Bool {
            if exactTitle != other.exactTitle { return exactTitle }
            if exactAlbum != other.exactAlbum { return exactAlbum }
            if titleSimilarity != other.titleSimilarity { return titleSimilarity > other.titleSimilarity }
            if artistSimilarity != other.artistSimilarity { return artistSimilarity > other.artistSimilarity }
            return albumSimilarity > other.albumSimilarity
        }
    }

    static func queries(title: String, artist: String?, album: String?) -> [Query] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = cleanArtist(artist)
        let album = cleanAlbum(album)
        guard !title.isEmpty || !album.isEmpty else { return [] }

        var result: [Query] = []
        var seen = Set<Query>()
        func append(_ title: String, _ artist: String, _ album: String) {
            let query = Query(title: title, artist: artist, album: album)
            // A case-only change does not need another provider request.
            let key = Query(title: title.lowercased(), artist: artist.lowercased(), album: album.lowercased())
            if seen.insert(key).inserted { result.append(query) }
        }

        append(title, artist, album)
        if !title.isEmpty {
            if !album.isEmpty { append(title, artist, "") }
            let stripped = AMLLDBTitleNormalizer.stripVersionSuffix(title)
            let base = stripped.isEmpty ? title : stripped
            append(base, artist, "")
            if !artist.isEmpty { append(base, "", "") }

            let aliases = AMLLDBTitleNormalizer.extractAliases(title).aliases + bracketedAlternate(title)
            if let alternate = aliases.first(where: { !exact($0, base) }) {
                append(alternate, artist, "")
            }
        } else {
            let stripped = AMLLDBTitleNormalizer.stripVersionSuffix(album)
            let base = stripped.isEmpty ? album : stripped
            append("", artist, base)
            if !artist.isEmpty { append("", "", base) }
            let aliases = AMLLDBTitleNormalizer.extractAliases(album).aliases + bracketedAlternate(album)
            if let alternate = aliases.first(where: { !exact($0, base) }) {
                append("", artist, alternate)
            }
        }
        return Array(result.prefix(5))
    }

    static func exact(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = exactKey(lhs)
        return !left.isEmpty && left == exactKey(rhs)
    }

    static func rank(
        title: String?, artist: String?, album: String?,
        candidateTitle: String?, candidateArtist: String?, candidateAlbum: String?
    ) -> Rank {
        Rank(
            exactTitle: exact(title, candidateTitle),
            exactAlbum: exact(cleanAlbum(album), candidateAlbum),
            titleSimilarity: similarity(title, candidateTitle),
            artistSimilarity: artistSimilarity(artist, candidateArtist),
            albumSimilarity: similarity(cleanAlbum(album), candidateAlbum)
        )
    }

    static func canAutomaticallyPreview(_ candidate: CoverCandidate, title: String?, artist: String?, album: String?) -> Bool {
        let cleanArtist = cleanArtist(artist)
        let nameMatches = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? exact(title, candidate.matchedTitle)
            : exact(cleanAlbum(album), candidate.matchedAlbum)
        guard nameMatches, !cleanArtist.isEmpty,
              candidate.confidence >= CoverLookupConfiguration.automaticCoverConfidenceThreshold else { return false }
        return artistSimilarity(cleanArtist, candidate.matchedArtist) >= 0.85
    }

    static func sortMetadataCandidates(
        _ candidates: [QQMusicArtworkCandidate], title: String, artist: String, album: String
    ) -> [QQMusicArtworkCandidate] {
        func rank(_ candidate: QQMusicArtworkCandidate) -> Rank {
            Self.rank(title: title, artist: artist, album: album,
                candidateTitle: candidate.title, candidateArtist: candidate.artist ?? candidate.artistName,
                candidateAlbum: candidate.album)
        }
        let sorted = candidates.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            if left != right { return left.isBetter(than: right) }
            return lhs.offset < rhs.offset
        }
        var seen = Set<String>()
        return sorted.compactMap { item in
            guard let id = item.element.songMid, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return item.element
        }
    }

    static func cleanArtist(_ value: String?) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LibraryNormalization.isUnknownArtist(text) ? "" : text
    }

    static func cleanAlbum(_ value: String?) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LibraryNormalization.isUnknownAlbum(text) ? "" : text
    }

    static func similarity(_ lhs: String?, _ rhs: String?) -> Double {
        ExternalPlaybackTextNormalizer.stringSimilarity(
            ExternalPlaybackTextNormalizer.normalize(lhs), ExternalPlaybackTextNormalizer.normalize(rhs)
        )
    }

    private static func artistSimilarity(_ lhs: String?, _ rhs: String?) -> Double {
        ExternalPlaybackTextNormalizer.artistSimilarity(
            ExternalPlaybackTextNormalizer.normalizeArtist(cleanArtist(lhs)),
            ExternalPlaybackTextNormalizer.normalizeArtist(rhs)
        )
    }

    private static func exactKey(_ value: String?) -> String {
        let folded = (value ?? "").precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }.joined()
    }

    private static func bracketedAlternate(_ title: String) -> [String] {
        let pattern = #"[（\(\[【]([^）\)\]】]+)[）\)\]】]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return [] }
        let text = String(title[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let annotations = ["live", "acoustic", "version", "remix", "remaster", "feat", "ost", "instrumental",
                           "电影", "电视剧", "网剧", "主题曲", "片尾曲", "插曲", "现场", "伴奏", "翻唱", "原声"]
        guard text.count >= 2, !annotations.contains(where: { lower.contains($0) }) else { return [] }
        return [text]
    }
}
