//
//  LibraryNormalization.swift
//  myPlayer2
//
//  Normalization rules for runtime grouping and dedup keys.
//

import Foundation

struct LibraryAlbumGroupingResult {
    let sections: [AlbumSection]
    let albumKeyByTrackID: [UUID: String]
}

nonisolated enum LibraryNormalization {
    static let unknownTitle = "未知歌曲"
    static let unknownArtist = LibraryTextNormalization.unknownArtist
    static let unknownAlbum = "未知专辑"
    static let variousArtists = "Various Artists"

    /// §10.4: an explicit COMPILATION flag is authoritative evidence and is
    /// consulted before any alias-string guessing; `false` is equally
    /// authoritative because TCMP=0 explicitly marks a non-compilation.
    static func isCompilationAlbumType(
        _ value: String?,
        primaryArtist: String? = nil,
        explicitCompilation: Bool? = nil
    ) -> Bool {
        if let explicitCompilation { return explicitCompilation }
        let candidates = [value, primaryArtist].compactMap { optional in
            optional?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let aliases: Set<String> = [
            "compilation",
            "various artists",
            "variousartists",
            "various artist",
            "合辑",
            "合集",
            "群星",
            "群星合集",
            "杂锦"
        ]
        return candidates.contains { aliases.contains(comparisonKey($0).replacingOccurrences(of: " ", with: ""))
            || aliases.contains(comparisonKey($0)) }
    }

    private static let unknownAlbumAliases = [
        "",
        "unknown album",
        "untitled album",
        "无专辑",
        "未知专辑",
        "未知唱片集",
        "未标注专辑"
    ]
    private static let albumArtistDisambiguationPrefix = "albumartist:"
    private static let artistClusterDisambiguationPrefix = "artistcluster:"
    private static let musicBrainzDisambiguationPrefix = "mbid:"
    private static let releaseYearDisambiguationPrefix = "year:"
    private static let folderHintDisambiguationPrefix = "folder:"

    enum AlbumKeyDisambiguation {
        case none
        case albumArtist(String)
        case artistCluster(String)
        case musicBrainzRelease(String)
        case releaseYear(Int)
        case folder(String)
    }

    static func normalizeTitle(_ value: String?) -> String {
        normalize(value, fallback: unknownTitle)
    }

    static func normalizeArtist(_ value: String?) -> String {
        normalize(value, fallback: unknownArtist)
    }

    static func normalizeAlbum(_ value: String?) -> String {
        comparisonKey(canonicalAlbumTitle(value))
    }

    static func normalizedDedupKey(title: String?, artist: String?) -> String {
        "\(normalizeTitle(title))•\(normalizeArtist(artist))"
    }

    static func normalizedAlbumKey(album: String?) -> String {
        normalizeAlbum(album)
    }

    static func normalizedAlbumKey(album: String?, artist _: String?) -> String {
        normalizedAlbumKey(album: album)
    }

    static func displayTitle(_ value: String?) -> String {
        display(value, fallback: unknownTitle)
    }

    static func displayArtist(_ value: String?) -> String {
        display(value, fallback: unknownArtist)
    }

    static func artistComponents(_ value: String?) -> [(canonicalName: String, displayName: String)] {
        let displayName = displayArtist(value)
        let unknownKey = normalizeArtist(nil)
        guard normalizeArtist(displayName) != unknownKey else {
            return [(unknownKey, unknownArtist)]
        }

        let names = splitArtistDisplayNames(displayName)
        var seen: Set<String> = []
        var components: [(canonicalName: String, displayName: String)] = []
        for name in names {
            let key = normalizeArtist(name)
            guard key != unknownKey, !seen.contains(key) else { continue }
            seen.insert(key)
            components.append((key, name))
        }

        if components.isEmpty {
            return [(normalizeArtist(displayName), displayName)]
        }
        return components
    }

    static func artistCanonicalNames(_ value: String?) -> [String] {
        artistComponents(value).map { $0.canonicalName }
    }

    /// Uses structured credits when they contain more than the compatibility
    /// fallback entry. A one-entry fallback deliberately returns to the raw
    /// parser so old tags such as "A, B" keep their established projection.
    static func artistComponents(for track: Track) -> [(canonicalName: String, displayName: String)] {
        let credits = track.artistCredits.filter { $0.role.isArtistContributor }
        guard credits.count > 1 else {
            return artistComponents(track.artist)
        }

        var seen: Set<String> = []
        return credits.compactMap { credit in
            let canonicalName = normalizeArtist(credit.canonicalName)
            guard canonicalName != normalizeArtist(nil), !seen.contains(canonicalName) else {
                return nil
            }
            seen.insert(canonicalName)
            return (canonicalName: canonicalName, displayName: displayArtist(credit.displayName))
        }
    }

    static func artistCanonicalNames(for track: Track) -> [String] {
        artistComponents(for: track).map(\.canonicalName)
    }

    static func containsArtist(_ canonicalName: String, in track: Track) -> Bool {
        artistCanonicalNames(for: track).contains(canonicalName)
    }

    static func containsArtist(_ canonicalName: String, in value: String?) -> Bool {
        artistCanonicalNames(value).contains(canonicalName)
    }

    static func replacingArtistComponent(
        in value: String,
        matching canonicalName: String,
        with replacementDisplayName: String
    ) -> String {
        let replacement = displayArtist(replacementDisplayName)
        let parts = artistSplitPattern?
            .matches(in: value, range: NSRange(value.startIndex..., in: value)) ?? []

        guard !parts.isEmpty else {
            return containsArtist(canonicalName, in: value) ? replacement : value
        }

        var result = ""
        var cursor = value.startIndex
        var replaced = false
        for match in parts {
            guard let range = Range(match.range, in: value) else { continue }
            let segment = String(value[cursor..<range.lowerBound])
            result += replacementSegmentIfNeeded(
                segment,
                canonicalName: canonicalName,
                replacement: replacement,
                didReplace: &replaced
            )
            result += String(value[range])
            cursor = range.upperBound
        }

        let segment = String(value[cursor...])
        result += replacementSegmentIfNeeded(
            segment,
            canonicalName: canonicalName,
            replacement: replacement,
            didReplace: &replaced
        )
        return replaced ? result : value
    }

    static func displayAlbum(_ value: String?) -> String {
        let canonical = canonicalAlbumTitle(value)
        return comparisonKey(canonical) == comparisonKey(unknownAlbum)
            ? ""
            : canonical
    }

    static func displayAlbumGroupTitle(_ value: String?) -> String {
        let canonical = canonicalAlbumTitle(value)
        return comparisonKey(canonical) == comparisonKey(unknownAlbum)
            ? NSLocalizedString("library.unknown_album", comment: "")
            : canonical
    }

    static func isUnknownAlbum(_ value: String?) -> Bool {
        comparisonKey(canonicalAlbumTitle(value)) == comparisonKey(unknownAlbum)
    }

    /// §10.3 evidence-aware album key. Priority: MusicBrainz Release ID wins
    /// over every hint; the release year disambiguates only when no album
    /// artist does; the folder hint applies only when MBID, album artist and
    /// year are all absent — the source folder is the weakest clue and must
    /// never outrank tag evidence. Default parameters keep legacy callers
    /// byte-compatible.
    static func composeAlbumKey(
        album: String?,
        disambiguation: AlbumKeyDisambiguation = .none,
        musicBrainzReleaseID: String? = nil,
        releaseYear: Int? = nil,
        folderHint: String? = nil
    ) -> String {
        let base = normalizedAlbumKey(album: album)
        if let trimmedMBID = musicBrainzReleaseID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedMBID.isEmpty {
            return "\(base)•\(musicBrainzDisambiguationPrefix)\(trimmedMBID)"
        }
        switch disambiguation {
        case .none:
            if let releaseYear {
                return "\(base)•\(releaseYearDisambiguationPrefix)\(releaseYear)"
            }
            if let folderHint, !folderHint.isEmpty {
                return "\(base)•\(folderHintDisambiguationPrefix)\(comparisonKey(folderHint))"
            }
            return base
        case .albumArtist(let artistKey):
            return "\(base)•\(albumArtistDisambiguationPrefix)\(artistKey)"
        case .artistCluster(let artistKey):
            return "\(base)•\(artistClusterDisambiguationPrefix)\(artistKey)"
        case .musicBrainzRelease(let id):
            return "\(base)•\(musicBrainzDisambiguationPrefix)\(id)"
        case .releaseYear(let year):
            return "\(base)•\(releaseYearDisambiguationPrefix)\(year)"
        case .folder(let hint):
            return "\(base)•\(folderHintDisambiguationPrefix)\(hint)"
        }
    }

    static func retitledAlbumKey(existingKey: String, newAlbumTitle: String) -> String {
        composeAlbumKey(album: newAlbumTitle, disambiguation: parseAlbumKey(existingKey).disambiguation)
    }

    static func renamedArtistAlbumKey(existingKey: String, newArtistCanonicalName: String) -> String {
        let parsed = parseAlbumKey(existingKey)
        switch parsed.disambiguation {
        case .artistCluster:
            return composeAlbumKey(
                album: parsed.normalizedAlbumTitle,
                disambiguation: .artistCluster(newArtistCanonicalName)
            )
        case .albumArtist, .none, .musicBrainzRelease, .releaseYear, .folder:
            return existingKey
        }
    }

    static func buildAlbumGrouping(tracks: [Track]) -> LibraryAlbumGroupingResult {
        let titleBuckets = Dictionary(grouping: tracks) { normalizedAlbumKey(album: $0.album) }
        var sections: [AlbumSection] = []
        var albumKeyByTrackID: [UUID: String] = [:]

        for bucketTracks in titleBuckets.values {
            for group in splitAlbumBucket(bucketTracks) {
                let representative = representativeArtist(
                    for: group.tracks,
                    preferredKey: group.preferredArtistCanonicalName
                )
                sections.append(
                    AlbumSection(
                        key: group.key,
                        name: displayAlbumGroupTitle(group.tracks.first?.album),
                        artistName: representative.displayName,
                        artistCanonicalName: representative.canonicalName,
                        memberArtistCanonicalNames: group.memberArtistCanonicalNames,
                        trackCount: group.tracks.count
                    )
                )
                for track in group.tracks {
                    albumKeyByTrackID[track.id] = group.key
                }
            }
        }

        return LibraryAlbumGroupingResult(
            sections: sections.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            albumKeyByTrackID: albumKeyByTrackID
        )
    }

    private static func normalize(_ value: String?, fallback: String) -> String {
        LibraryTextNormalization.normalize(value, fallback: fallback)
    }

    private static func display(_ value: String?, fallback: String) -> String {
        LibraryTextNormalization.display(value, fallback: fallback)
    }

    private static func collapsedWhitespace(_ value: String?) -> String {
        LibraryTextNormalization.collapsedWhitespace(value)
    }

    private static var artistSplitPattern: NSRegularExpression? {
        // "&", "+" and "/" are deliberately absent: plan §10.2/§3 forbids
        // splitting them without explicit user confirmation.
        do {
            return try NSRegularExpression(
                pattern: #"\s*(?:[,;、，；×]|\\|\b(?:feat\.?|ft\.?|featuring|with|vs\.?)\b)\s*"#,
                options: [.caseInsensitive]
            )
        } catch {
            Log.error("Failed to compile artist split pattern: \(error)", category: .library)
            return nil
        }
    }

    private static func splitArtistDisplayNames(_ value: String) -> [String] {
        let prepared = value
            .replacingOccurrences(
                of: "[（(]\\s*(?:feat\\.?|ft\\.?|featuring|with)\\b",
                with: "; ",
                options: [.regularExpression, .caseInsensitive]
            )
        let matches = artistSplitPattern?.matches(
            in: prepared,
            range: NSRange(prepared.startIndex..., in: prepared)
        ) ?? []
        guard !matches.isEmpty else { return [collapsedArtistComponent(prepared)].filter { !$0.isEmpty } }

        var names: [String] = []
        var cursor = prepared.startIndex
        for match in matches {
            guard let range = Range(match.range, in: prepared) else { continue }
            names.append(collapsedArtistComponent(String(prepared[cursor..<range.lowerBound])))
            cursor = range.upperBound
        }
        names.append(collapsedArtistComponent(String(prepared[cursor...])))
        return names.filter { !$0.isEmpty }
    }

    private static func collapsedArtistComponent(_ value: String) -> String {
        collapsedWhitespace(value)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "（）()[]【】")
            ))
    }

    private static func replacementSegmentIfNeeded(
        _ segment: String,
        canonicalName: String,
        replacement: String,
        didReplace: inout Bool
    ) -> String {
        let component = collapsedArtistComponent(segment)
        guard !component.isEmpty, normalizeArtist(component) == canonicalName else {
            return segment
        }

        didReplace = true
        guard
            let start = segment.firstIndex(where: { !$0.isWhitespace }),
            let end = segment.lastIndex(where: { !$0.isWhitespace })
        else {
            return replacement
        }
        return String(segment[..<start]) + replacement + String(segment[segment.index(after: end)...])
    }

    private static func canonicalAlbumTitle(_ value: String?) -> String {
        let collapsed = collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return unknownAlbum }
        return unknownAlbumAliases.contains(comparisonKey(collapsed)) ? unknownAlbum : collapsed
    }

    private static func comparisonKey(_ value: String) -> String {
        LibraryTextNormalization.comparisonKey(value)
    }

    private static func parseAlbumKey(_ key: String) -> (
        normalizedAlbumTitle: String, disambiguation: AlbumKeyDisambiguation
    ) {
        let albumArtistMarker = "•\(albumArtistDisambiguationPrefix)"
        if let range = key.range(of: albumArtistMarker) {
            let base = String(key[..<range.lowerBound])
            let artistKey = String(key[range.upperBound...])
            return (base, .albumArtist(artistKey))
        }

        let artistClusterMarker = "•\(artistClusterDisambiguationPrefix)"
        if let range = key.range(of: artistClusterMarker) {
            let base = String(key[..<range.lowerBound])
            let artistKey = String(key[range.upperBound...])
            return (base, .artistCluster(artistKey))
        }

        let musicBrainzMarker = "•\(musicBrainzDisambiguationPrefix)"
        if let range = key.range(of: musicBrainzMarker) {
            let base = String(key[..<range.lowerBound])
            let mbid = String(key[range.upperBound...])
            return (base, .musicBrainzRelease(mbid))
        }

        let yearMarker = "•\(releaseYearDisambiguationPrefix)"
        if let range = key.range(of: yearMarker),
           let year = Int(String(key[range.upperBound...])) {
            let base = String(key[..<range.lowerBound])
            return (base, .releaseYear(year))
        }

        let folderMarker = "•\(folderHintDisambiguationPrefix)"
        if let range = key.range(of: folderMarker) {
            let base = String(key[..<range.lowerBound])
            let hint = String(key[range.upperBound...])
            return (base, .folder(hint))
        }

        return (key, .none)
    }

    private static func normalizedNonUnknownArtist(_ value: String?) -> String? {
        let collapsed = collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return nil }
        let normalized = normalizeArtist(collapsed)
        return normalized == normalizeArtist(nil) ? nil : normalized
    }

    private static func primaryArtistClusterKey(_ value: String?) -> String? {
        let collapsed = collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return nil }

        let simplified = collapsed
            .replacingOccurrences(
                of: "\\s*(?:\\(|（)?(?:feat\\.?|ft\\.?|featuring|with)\\b.*$",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedNonUnknownArtist(simplified)
    }

    private static func splitAlbumBucket(_ tracks: [Track]) -> [(
        key: String,
        tracks: [Track],
        preferredArtistCanonicalName: String?,
        memberArtistCanonicalNames: [String]
    )] {
        guard let firstTrack = tracks.first else { return [] }
        let baseKey = normalizedAlbumKey(album: firstTrack.album)

        if baseKey == normalizedAlbumKey(album: nil) {
            return [(
                key: baseKey,
                tracks: tracks,
                preferredArtistCanonicalName: nil,
                memberArtistCanonicalNames: memberArtistCanonicalNames(for: tracks)
            )]
        }

        // §10.4: an explicit COMPILATION marker outranks every grouping
        // heuristic — a compilation stays one bucket and its track artists
        // remain untouched inside it.
        if tracks.contains(where: { $0.embeddedCompilation == true }) {
            return [(
                key: baseKey,
                tracks: tracks,
                preferredArtistCanonicalName: nil,
                memberArtistCanonicalNames: memberArtistCanonicalNames(for: tracks)
            )]
        }

        // §10.3 tier 1: a MusicBrainz Release ID shared by the whole bucket is
        // stronger than any name-based reasoning. Partial tag coverage keeps
        // the legacy path so untagged siblings are not orphaned into a split.
        var trustedMBIDGroups: [String: [Track]] = [:]
        for track in tracks {
            guard let mbid = trustedMusicBrainzReleaseID(track) else { continue }
            trustedMBIDGroups[mbid, default: []].append(track)
        }
        if !trustedMBIDGroups.isEmpty,
           trustedMBIDGroups.values.flatMap({ $0 }).count == tracks.count,
           trustedMBIDGroups.values.allSatisfy({ $0.count >= 2 }) {
            return trustedMBIDGroups
                .sorted { $0.key < $1.key }
                .map { mbid, groupedTracks in
                    (
                        key: composeAlbumKey(
                            album: groupedTracks.first?.album,
                            musicBrainzReleaseID: mbid
                        ),
                        tracks: groupedTracks,
                        preferredArtistCanonicalName: nil,
                        memberArtistCanonicalNames: memberArtistCanonicalNames(for: groupedTracks)
                    )
                }
        }

        var trustedAlbumArtistGroups: [String: [Track]] = [:]
        for track in tracks {
            guard let artistKey = normalizedNonUnknownArtist(track.albumArtist) else { continue }
            trustedAlbumArtistGroups[artistKey, default: []].append(track)
        }

        if trustedAlbumArtistGroups.count > 1
            && trustedAlbumArtistGroups.values.flatMap({ $0 }).count == tracks.count
        {
            return trustedAlbumArtistGroups
                .sorted { $0.key < $1.key }
                .map { artistKey, groupedTracks in
                    (
                        key: composeAlbumKey(
                            album: groupedTracks.first?.album,
                            disambiguation: .albumArtist(artistKey)
                        ),
                        tracks: groupedTracks,
                        preferredArtistCanonicalName: artistKey,
                        memberArtistCanonicalNames: memberArtistCanonicalNames(for: groupedTracks)
                    )
                }
        }

        var trustedTrackArtistGroups: [String: [Track]] = [:]
        for track in tracks {
            guard let artistKey = primaryArtistClusterKey(for: track) else { continue }
            trustedTrackArtistGroups[artistKey, default: []].append(track)
        }
        let canSplitByTrackArtist =
            trustedAlbumArtistGroups.isEmpty
            && trustedTrackArtistGroups.count == 2
            && trustedTrackArtistGroups.values.flatMap({ $0 }).count == tracks.count
            && tracks.count >= 4
            && trustedTrackArtistGroups.values.allSatisfy { $0.count >= 2 }

        if canSplitByTrackArtist {
            return trustedTrackArtistGroups
                .sorted { $0.key < $1.key }
                .map { artistKey, groupedTracks in
                    (
                        key: composeAlbumKey(
                            album: groupedTracks.first?.album,
                            disambiguation: .artistCluster(artistKey)
                        ),
                        tracks: groupedTracks,
                        preferredArtistCanonicalName: artistKey,
                        memberArtistCanonicalNames: memberArtistCanonicalNames(for: groupedTracks)
                    )
                }
        }

        // §10.3 tier 2: with no album artist anywhere, differing release
        // years on fully-tagged tracks disambiguate same-named albums. A
        // single untagged track keeps the legacy merged bucket because a
        // partial year tag must never split an album.
        if trustedAlbumArtistGroups.isEmpty {
            let yearGroups = Dictionary(grouping: tracks) { $0.embeddedReleaseYear }
            if yearGroups.count > 1, !yearGroups.keys.contains(nil) {
                return yearGroups
                    .sorted { ($0.key ?? 0) < ($1.key ?? 0) }
                    .map { year, groupedTracks in
                        (
                            key: composeAlbumKey(
                                album: groupedTracks.first?.album,
                                releaseYear: year
                            ),
                            tracks: groupedTracks,
                            preferredArtistCanonicalName: nil,
                            memberArtistCanonicalNames: memberArtistCanonicalNames(for: groupedTracks)
                        )
                    }
            }
        }

        return [(
            key: baseKey,
            tracks: tracks,
            preferredArtistCanonicalName: trustedAlbumArtistGroups.keys.sorted().first,
            memberArtistCanonicalNames: memberArtistCanonicalNames(for: tracks)
        )]
    }

    private static func trustedMusicBrainzReleaseID(_ track: Track) -> String? {
        let trimmed = track.musicBrainzReleaseID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func memberArtistCanonicalNames(for tracks: [Track]) -> [String] {
        Set(tracks.flatMap { artistCanonicalNames(for: $0) }).sorted()
    }

    private static func primaryArtistClusterKey(for track: Track) -> String? {
        if let primary = track.artistCredits.first(where: { $0.role == .primary }),
           track.artistCredits.count > 1 {
            return normalizedNonUnknownArtist(primary.canonicalName)
        }
        return primaryArtistClusterKey(track.artist)
    }

    private static func representativeArtist(
        for tracks: [Track],
        preferredKey: String?
    ) -> (canonicalName: String, displayName: String) {
        if let preferredKey {
            if let preferredTrack = tracks.first(where: {
                normalizedNonUnknownArtist($0.albumArtist) == preferredKey
                    || primaryArtistClusterKey(for: $0) == preferredKey
                    || normalizeArtist($0.artist) == preferredKey
            }) {
                let albumArtistDisplay = collapsedWhitespace(preferredTrack.albumArtist)
                if !albumArtistDisplay.isEmpty {
                    return (preferredKey, albumArtistDisplay)
                }
                return (preferredKey, displayArtist(preferredTrack.artist))
            }
        }

        let groupedByArtist = Dictionary(grouping: tracks) {
            primaryArtistClusterKey(for: $0) ?? normalizeArtist(nil)
        }
        if let dominant = groupedByArtist.max(by: { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.key > rhs.key
            }
            return lhs.value.count < rhs.value.count
        }) {
            let representative = dominant.value.first
            let primary = representative?.artistCredits.first(where: { $0.role == .primary })
            return (
                dominant.key,
                primary.map { displayArtist($0.displayName) }
                    ?? displayArtist(representative?.artist)
            )
        }

        return (normalizeArtist(nil), displayArtist(nil))
    }
}
