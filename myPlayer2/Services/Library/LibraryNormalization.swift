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
    static let unknownArtist = "未知歌手"
    static let unknownAlbum = "未知专辑"

    private static let unknownAlbumAliases = [
        "",
        "unknown album",
        "未知专辑"
    ]
    private static let albumArtistDisambiguationPrefix = "albumartist:"
    private static let artistClusterDisambiguationPrefix = "artistcluster:"

    enum AlbumKeyDisambiguation {
        case none
        case albumArtist(String)
        case artistCluster(String)
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

    static func displayAlbum(_ value: String?) -> String {
        canonicalAlbumTitle(value)
    }

    static func composeAlbumKey(
        album: String?,
        disambiguation: AlbumKeyDisambiguation = .none
    ) -> String {
        let base = normalizedAlbumKey(album: album)
        switch disambiguation {
        case .none:
            return base
        case .albumArtist(let artistKey):
            return "\(base)•\(albumArtistDisambiguationPrefix)\(artistKey)"
        case .artistCluster(let artistKey):
            return "\(base)•\(artistClusterDisambiguationPrefix)\(artistKey)"
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
        case .albumArtist, .none:
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
                        name: displayAlbum(group.tracks.first?.album),
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
        comparisonKey(display(value, fallback: fallback))
    }

    private static func display(_ value: String?, fallback: String) -> String {
        let collapsed = collapsedWhitespace(value)
        return collapsed.isEmpty ? fallback : collapsed
    }

    private static func collapsedWhitespace(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func canonicalAlbumTitle(_ value: String?) -> String {
        let collapsed = collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return unknownAlbum }
        return unknownAlbumAliases.contains(comparisonKey(collapsed)) ? unknownAlbum : collapsed
    }

    private static func comparisonKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
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
            guard let artistKey = primaryArtistClusterKey(track.artist) else { continue }
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

        return [(
            key: baseKey,
            tracks: tracks,
            preferredArtistCanonicalName: trustedAlbumArtistGroups.keys.sorted().first,
            memberArtistCanonicalNames: memberArtistCanonicalNames(for: tracks)
        )]
    }

    private static func memberArtistCanonicalNames(for tracks: [Track]) -> [String] {
        Set(tracks.map { normalizeArtist($0.artist) }).sorted()
    }

    private static func representativeArtist(
        for tracks: [Track],
        preferredKey: String?
    ) -> (canonicalName: String, displayName: String) {
        if let preferredKey {
            if let preferredTrack = tracks.first(where: {
                normalizedNonUnknownArtist($0.albumArtist) == preferredKey
                    || primaryArtistClusterKey($0.artist) == preferredKey
                    || normalizeArtist($0.artist) == preferredKey
            }) {
                let albumArtistDisplay = collapsedWhitespace(preferredTrack.albumArtist)
                if !albumArtistDisplay.isEmpty {
                    return (preferredKey, albumArtistDisplay)
                }
                return (preferredKey, displayArtist(preferredTrack.artist))
            }
        }

        let groupedByArtist = Dictionary(grouping: tracks) { normalizeArtist($0.artist) }
        if let dominant = groupedByArtist.max(by: { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.key > rhs.key
            }
            return lhs.value.count < rhs.value.count
        }) {
            return (dominant.key, displayArtist(dominant.value.first?.artist))
        }

        return (normalizeArtist(nil), displayArtist(nil))
    }
}
