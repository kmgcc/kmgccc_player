import CryptoKit
import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationLibraryQueries {
    private weak var appSession: AppSessionHost?

    init(appSession: AppSessionHost?) {
        self.appSession = appSession
    }

    func resolveSelection(
        _ snapshot: AutomationSelectionSnapshot,
        viewModel: LibraryViewModel
    ) throws -> (summary: AutomationSelectionSummary, trackIDs: [UUID]) {
        guard let filter = snapshot.filter else {
            return (snapshot.summary, snapshot.trackIDs)
        }
        try validateTrackFilter(filter)
        let preferenceStatsByTrackID = AutomationTrackPreferenceQuery.requiresHistoryRead(in: filter)
            ? viewModel.preferenceStats(for: viewModel.allTracks.map(\.id))
            : [:]
        let trackIDs = try viewModel.allTracks.compactMap { track in
            try matchesTrackFilter(
                track,
                filter: filter,
                playlists: viewModel.playlists,
                preferenceStatsByTrackID: preferenceStatsByTrackID
            ) ? track.id : nil
        }
        guard trackIDs.count <= 10_000 else {
            throw AutomationParameterError.outOfRange("filter.resultCount")
        }
        let summary = AutomationSelectionSummary(
            id: snapshot.summary.id,
            name: snapshot.summary.name,
            trackCount: trackIDs.count,
            revision: selectionRevision(libraryID: snapshot.libraryID, trackIDs: trackIDs),
            createdAt: snapshot.summary.createdAt,
            expiresAt: snapshot.summary.expiresAt,
            isDynamic: true
        )
        return (summary, trackIDs)
    }

    func validateTrackFilter(_ filter: AutomationJSONValue) throws {
        _ = try validateTrackFilter(filter, depth: 0, visited: 0)
    }

    @discardableResult
    private func validateTrackFilter(
        _ filter: AutomationJSONValue,
        depth: Int,
        visited: Int
    ) throws -> Int {
        guard depth <= 8, visited < 256 else {
            throw AutomationParameterError.outOfRange("filter.complexity")
        }
        guard case .object(let values) = filter, values.count <= 64 else {
            throw AutomationParameterError.invalidType("filter", expected: "bounded object")
        }
        var count = visited + 1
        for (key, value) in values {
            switch key {
            case "all", "any":
                guard case .array(let children) = value,
                      children.count <= 100,
                      key != "any" || !children.isEmpty else {
                    throw AutomationParameterError.invalidType("filter.\(key)", expected: "bounded array of filters")
                }
                for child in children {
                    count = try validateTrackFilter(child, depth: depth + 1, visited: count)
                }
            case "not":
                count = try validateTrackFilter(value, depth: depth + 1, visited: count)
            case "id", "sourceID", "playlistID":
                guard case .string(let raw) = value, UUID(uuidString: raw) != nil else {
                    throw AutomationParameterError.invalidValue("filter.\(key)")
                }
            case "ids":
                guard case .array(let rawIDs) = value, rawIDs.count <= 10_000 else {
                    throw AutomationParameterError.invalidType("filter.ids", expected: "bounded array of UUID strings")
                }
                for rawID in rawIDs {
                    guard case .string(let raw) = rawID, UUID(uuidString: raw) != nil else {
                        throw AutomationParameterError.invalidValue("filter.ids")
                    }
                }
            case "text", "titleContains", "artistContains", "albumContains", "genreContains", "codec", "format":
                guard case .string(let text) = value, text.count <= 1_000 else {
                    throw AutomationParameterError.invalidType("filter.\(key)", expected: "string up to 1000 characters")
                }
            case "availability":
                guard case .string(let raw) = value,
                      TrackAvailability(rawValue: raw) != nil else {
                    throw AutomationParameterError.invalidValue("filter.availability")
                }
            case "missing", "hasLyrics", "hasArtwork":
                guard case .boolean = value else {
                    throw AutomationParameterError.invalidType("filter.\(key)", expected: "boolean")
                }
            case "lyricsStatus":
                guard case .string(let status) = value,
                      ["none", "wordSynced", "lineSynced", "plain"].contains(status) else {
                    throw AutomationParameterError.invalidValue("filter.lyricsStatus")
                }
            case "addedAfter", "addedBefore", "releaseAfter", "releaseBefore",
                 "lastPlayedAfter", "lastPlayedBefore":
                _ = try filterDate(value, key: key)
            case "durationMin", "durationMax", "metadataConfidenceMin",
                 "totalPlayedSecondsMin", "preferenceScoreMin":
                guard case .number(let number) = value, number.isFinite else {
                    throw AutomationParameterError.invalidType("filter.\(key)", expected: "finite number")
                }
                if key == "metadataConfidenceMin", !(0...1).contains(number) {
                    throw AutomationParameterError.outOfRange("filter.\(key)")
                }
                if key == "totalPlayedSecondsMin", number < 0 {
                    throw AutomationParameterError.outOfRange("filter.\(key)")
                }
            case "likeState":
                guard case .string(let rawValue) = value,
                      ManualLikeState(rawValue: rawValue) != nil else {
                    throw AutomationParameterError.invalidValue("filter.likeState")
                }
            case "playCountMin", "playCountMax", "completePlayCountMin", "skipCountMin":
                guard case .number(let number) = value,
                      number.isFinite,
                      number >= 0,
                      number.rounded() == number else {
                    throw AutomationParameterError.invalidValue("filter.\(key)")
                }
            case "sampleRateHz", "bitDepth":
                guard case .number(let number) = value,
                      number.isFinite,
                      number.rounded() == number,
                      number > 0 else {
                    throw AutomationParameterError.invalidValue("filter.\(key)")
                }
            default:
                throw AutomationParameterError.invalidValue("filter.\(key)")
            }
        }
        return count
    }

    func matchesTrackFilter(
        _ track: Track,
        filter: AutomationJSONValue,
        playlists: [Playlist],
        preferenceStatsByTrackID: [UUID: TrackPreferenceStats] = [:]
    ) throws -> Bool {
        guard case .object(let values) = filter else {
            throw AutomationParameterError.invalidType("filter", expected: "object")
        }

        if let all = values["all"] {
            guard case .array(let filters) = all else {
                throw AutomationParameterError.invalidType("filter.all", expected: "array")
            }
            for child in filters where try !matchesTrackFilter(
                track,
                filter: child,
                playlists: playlists,
                preferenceStatsByTrackID: preferenceStatsByTrackID
            ) {
                return false
            }
        }
        if let any = values["any"] {
            guard case .array(let filters) = any, !filters.isEmpty else {
                throw AutomationParameterError.invalidType("filter.any", expected: "non-empty array")
            }
            var matched = false
            for child in filters where try matchesTrackFilter(
                track,
                filter: child,
                playlists: playlists,
                preferenceStatsByTrackID: preferenceStatsByTrackID
            ) {
                matched = true
                break
            }
            if !matched { return false }
        }
        if let not = values["not"] {
            if try matchesTrackFilter(
                track,
                filter: not,
                playlists: playlists,
                preferenceStatsByTrackID: preferenceStatsByTrackID
            ) { return false }
        }

        let memberships = track.mediaLocator.referencedFile?.allSourceMemberships ?? []
        let playlistIDs = Set(
            playlists.lazy.filter { playlist in
                playlist.tracks.contains { $0.id == track.id }
            }.map(\.id)
        )
        let audio = track.mediaLocator.referencedFile?.locations.first?.audioProperties
            ?? track.audioProperties
        let lyricsStatus = trackLyricsStatus(track)
        let artworkAvailable = track.hasArtwork
        let preferenceStats = preferenceStatsByTrackID[track.id] ?? TrackPreferenceStats()

        for (key, value) in values where key != "all" && key != "any" && key != "not" {
            switch key {
            case "id":
                guard case .string(let raw) = value, UUID(uuidString: raw) == track.id else { return false }
            case "ids":
                guard case .array(let rawIDs) = value else {
                    throw AutomationParameterError.invalidType("filter.ids", expected: "array")
                }
                let ids = try rawIDs.map { value -> UUID in
                    guard case .string(let raw) = value, let id = UUID(uuidString: raw) else {
                        throw AutomationParameterError.invalidValue("filter.ids")
                    }
                    return id
                }
                if !ids.contains(track.id) { return false }
            case "text":
                guard case .string(let text) = value else {
                    throw AutomationParameterError.invalidType("filter.text", expected: "string")
                }
                if !track.title.localizedCaseInsensitiveContains(text)
                    && !track.artist.localizedCaseInsensitiveContains(text)
                    && !track.album.localizedCaseInsensitiveContains(text) {
                    return false
                }
            case "titleContains":
                if try contains(value, key: key, in: track.title) == false { return false }
            case "artistContains":
                if try contains(value, key: key, in: track.artist) == false { return false }
            case "albumContains":
                if try contains(value, key: key, in: track.album) == false { return false }
            case "genreContains":
                let genres = track.genreTags.joined(separator: " ")
                if try contains(value, key: key, in: genres) == false { return false }
            case "sourceID":
                guard case .string(let raw) = value, let sourceID = UUID(uuidString: raw) else {
                    throw AutomationParameterError.invalidValue("filter.sourceID")
                }
                if !memberships.contains(where: { $0.sourceID == sourceID }) { return false }
            case "playlistID":
                guard case .string(let raw) = value, let playlistID = UUID(uuidString: raw) else {
                    throw AutomationParameterError.invalidValue("filter.playlistID")
                }
                if !playlistIDs.contains(playlistID) { return false }
            case "availability":
                guard case .string(let availability) = value else {
                    throw AutomationParameterError.invalidType("filter.availability", expected: "string")
                }
                if track.availability.rawValue != availability { return false }
            case "missing":
                guard case .boolean(let missing) = value else {
                    throw AutomationParameterError.invalidType("filter.missing", expected: "boolean")
                }
                if (track.availability == .missing) != missing { return false }
            case "hasLyrics":
                guard case .boolean(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.hasLyrics", expected: "boolean")
                }
                if (lyricsStatus != "none") != expected { return false }
            case "lyricsStatus":
                guard case .string(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.lyricsStatus", expected: "string")
                }
                if lyricsStatus != expected { return false }
            case "hasArtwork":
                guard case .boolean(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.hasArtwork", expected: "boolean")
                }
                if artworkAvailable != expected { return false }
            case "addedAfter":
                if let date = try filterDate(value, key: key), track.addedAt <= date { return false }
            case "addedBefore":
                if let date = try filterDate(value, key: key), track.addedAt >= date { return false }
            case "releaseAfter":
                guard let releaseDate = track.releaseDate,
                      let date = try filterDate(value, key: key), releaseDate > date else { return false }
            case "releaseBefore":
                guard let releaseDate = track.releaseDate,
                      let date = try filterDate(value, key: key), releaseDate < date else { return false }
            case "durationMin":
                guard case .number(let minimum) = value else {
                    throw AutomationParameterError.invalidType("filter.durationMin", expected: "number")
                }
                if track.duration < minimum { return false }
            case "durationMax":
                guard case .number(let maximum) = value else {
                    throw AutomationParameterError.invalidType("filter.durationMax", expected: "number")
                }
                if track.duration > maximum { return false }
            case "metadataConfidenceMin":
                guard case .number(let minimum) = value else {
                    throw AutomationParameterError.invalidType("filter.metadataConfidenceMin", expected: "number")
                }
                if (track.metadataConfidence ?? 0) < minimum { return false }
            case "codec":
                guard case .string(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.codec", expected: "string")
                }
                if audio?.codec?.localizedCaseInsensitiveCompare(expected) != .orderedSame { return false }
            case "format":
                guard case .string(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.format", expected: "string")
                }
                if audio?.format?.localizedCaseInsensitiveCompare(expected) != .orderedSame { return false }
            case "sampleRateHz":
                guard case .number(let expected) = value,
                      expected.isFinite,
                      expected.rounded() == expected else {
                    throw AutomationParameterError.invalidValue("filter.sampleRateHz")
                }
                if audio?.sampleRateHz != Int(expected) { return false }
            case "bitDepth":
                guard case .number(let expected) = value,
                      expected.isFinite,
                      expected.rounded() == expected else {
                    throw AutomationParameterError.invalidValue("filter.bitDepth")
                }
                if audio?.bitDepth != Int(expected) { return false }
            case "likeState", "playCountMin", "playCountMax", "completePlayCountMin",
                 "skipCountMin", "lastPlayedAfter", "lastPlayedBefore",
                 "totalPlayedSecondsMin", "preferenceScoreMin":
                if !AutomationTrackPreferenceQuery.matches(
                    key,
                    value: value,
                    stats: preferenceStats
                ) {
                    return false
                }
            default:
                throw AutomationParameterError.invalidValue("filter.\(key)")
            }
        }
        return true
    }

    private func contains(
        _ value: AutomationJSONValue,
        key: String,
        in text: String
    ) throws -> Bool {
        guard case .string(let needle) = value else {
            throw AutomationParameterError.invalidType("filter.\(key)", expected: "string")
        }
        return text.localizedCaseInsensitiveContains(needle)
    }

    private func filterDate(_ value: AutomationJSONValue, key: String) throws -> Date? {
        guard case .string(let raw) = value,
              let date = ISO8601DateFormatter().date(from: raw) else {
            throw AutomationParameterError.invalidValue("filter.\(key)")
        }
        return date
    }

    func sortTracks(
        _ tracks: [Track],
        using values: [AutomationJSONValue],
        preferenceStatsByTrackID: [UUID: TrackPreferenceStats] = [:]
    ) throws -> [Track] {
        struct SortKey {
            let field: String
            let descending: Bool
        }
        var keys: [SortKey] = []
        for value in values {
            guard case .object(let object) = value,
                  case .string(let field) = object["field"] else {
                throw AutomationParameterError.invalidValue("sort[(index)]")
            }
            let direction: String
            if case .string(let rawDirection) = object["direction"] {
                direction = rawDirection
            } else {
                direction = "asc"
            }
            guard direction == "asc" || direction == "desc" else {
                throw AutomationParameterError.invalidValue("sort[(index)].direction")
            }
            guard [
                "title", "artist", "album", "duration", "addedAt", "releaseDate",
                "availability", "codec", "sampleRateHz", "filePath",
                "likeState", "playCount", "completePlayCount", "skipCount",
                "lastPlayedAt", "totalPlayedSeconds", "preferenceScore"
            ].contains(field) else {
                throw AutomationParameterError.invalidValue("sort[(index)].field")
            }
            keys.append(SortKey(field: field, descending: direction == "desc"))
        }
        let effectiveKeys = keys.isEmpty
            ? [SortKey(field: "title", descending: false), SortKey(field: "artist", descending: false), SortKey(field: "album", descending: false)]
            : keys
        return tracks.sorted { lhs, rhs in
            for key in effectiveKeys {
                let comparison = compareTracks(
                    lhs,
                    rhs,
                    field: key.field,
                    preferenceStatsByTrackID: preferenceStatsByTrackID
                )
                if comparison == .orderedSame { continue }
                return key.descending
                    ? comparison == .orderedDescending
                    : comparison == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func compareTracks(
        _ lhs: Track,
        _ rhs: Track,
        field: String,
        preferenceStatsByTrackID: [UUID: TrackPreferenceStats]
    ) -> ComparisonResult {
        if let comparison = AutomationTrackPreferenceQuery.compare(
            preferenceStatsByTrackID[lhs.id] ?? TrackPreferenceStats(),
            preferenceStatsByTrackID[rhs.id] ?? TrackPreferenceStats(),
            field: field
        ) {
            return comparison
        }
        let lhsAudio = lhs.mediaLocator.referencedFile?.locations.first?.audioProperties ?? lhs.audioProperties
        let rhsAudio = rhs.mediaLocator.referencedFile?.locations.first?.audioProperties ?? rhs.audioProperties
        switch field {
        case "title": return lhs.title.localizedStandardCompare(rhs.title)
        case "artist": return lhs.artist.localizedStandardCompare(rhs.artist)
        case "album": return lhs.album.localizedStandardCompare(rhs.album)
        case "availability": return lhs.availability.rawValue.localizedStandardCompare(rhs.availability.rawValue)
        case "codec": return (lhsAudio?.codec ?? "").localizedStandardCompare(rhsAudio?.codec ?? "")
        case "filePath": return AutomationFileAccess.trackPath(lhs).localizedStandardCompare(AutomationFileAccess.trackPath(rhs))
        case "duration": return lhs.duration == rhs.duration ? .orderedSame : (lhs.duration < rhs.duration ? .orderedAscending : .orderedDescending)
        case "sampleRateHz":
            let left = lhsAudio?.sampleRateHz ?? 0
            let right = rhsAudio?.sampleRateHz ?? 0
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case "addedAt": return lhs.addedAt == rhs.addedAt ? .orderedSame : (lhs.addedAt < rhs.addedAt ? .orderedAscending : .orderedDescending)
        case "releaseDate":
            let left = lhs.releaseDate ?? .distantPast
            let right = rhs.releaseDate ?? .distantPast
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        default: return .orderedSame
        }
    }

    /// Build a deterministic snapshot token from the fields exposed by
    /// `library.tracks`, including the order of the library and Playlist
    /// membership. The token is intentionally opaque so callers can use it
    /// for optimistic pagination without receiving any additional metadata.
    func libraryTracksRevision(
        tracks: [Track],
        playlists: [Playlist],
        preferenceStatsByTrackID: [UUID: TrackPreferenceStats]? = nil
    ) -> String {
        var playlistIDsByTrackID: [UUID: Set<UUID>] = [:]
        for playlist in playlists {
            for track in playlist.tracks {
                playlistIDsByTrackID[track.id, default: []].insert(playlist.id)
            }
        }
        let summaries = tracks.map { track in
            makeTrackSummary(
                track,
                playlists: [],
                includeFilePath: false,
                playlistIDsOverride: Array(
                    playlistIDsByTrackID[track.id, default: []]
                ).sorted { $0.uuidString < $1.uuidString },
                includePreferenceStats: preferenceStatsByTrackID != nil,
                preferenceStats: preferenceStatsByTrackID?[track.id]
            )
        }
        guard let data = try? AutomationWireCoding.encoder().encode(summaries) else {
            return "v1-unavailable"
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "v1-" + digest
    }

    func selectionRevision(libraryID: UUID, trackIDs: [UUID]) -> String {
        let material = ([libraryID.uuidString] + trackIDs.map(\.uuidString)).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "selection-v1-" + digest
    }

    func trackLyricsStatus(_ track: Track) -> String {
        if let ttml = resolveTTMLText(for: track), !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.isWordSyncedTTML(ttml) ? "wordSynced" : "lineSynced"
        }
        if track.ttmlLyricsFileName != nil { return "lineSynced" }
        if let plain = resolvePlainLyricsText(for: track), !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.looksLikeLRC(plain) ? "lineSynced" : "plain"
        }
        if let lyricsFileName = track.lyricsFileName {
            return lyricsFileName.lowercased().hasSuffix(".lrc") ? "lineSynced" : "plain"
        }
        return "none"
    }

    func makeTrackSummary(
        _ track: Track,
        playlists: [Playlist] = [],
        includeFilePath: Bool = true,
        playlistIDsOverride: [UUID]? = nil,
        includePreferenceStats: Bool = false,
        preferenceStats: TrackPreferenceStats? = nil
    ) -> AutomationTrackSummary {
        let sourceMemberships = (track.mediaLocator.referencedFile?.allSourceMemberships ?? [])
            .map {
                AutomationTrackSourceMembership(
                    sourceID: $0.sourceID,
                    relativePath: $0.relativePath
                )
            }
            .sorted {
                if $0.sourceID != $1.sourceID {
                    return $0.sourceID.uuidString < $1.sourceID.uuidString
                }
                return $0.relativePath < $1.relativePath
            }
        let audio = track.mediaLocator.referencedFile?.locations.first?.audioProperties
            ?? track.audioProperties
        let playlistIDs: [UUID]
        if let playlistIDsOverride {
            playlistIDs = playlistIDsOverride.sorted { $0.uuidString < $1.uuidString }
        } else {
            playlistIDs = playlists
                .filter { playlist in playlist.tracks.contains { $0.id == track.id } }
                .map(\.id)
                .sorted { $0.uuidString < $1.uuidString }
        }
        return AutomationTrackSummary(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            availability: track.availability.rawValue,
            addedAt: track.addedAt,
            importedAt: track.importedAt,
            embeddedMetadataSnapshot: track.embeddedMetadataSnapshot.map { snapshot in
                AutomationEmbeddedMetadataSnapshot(
                    title: snapshot.title,
                    artistDisplay: snapshot.artistDisplay,
                    album: snapshot.album,
                    albumArtist: snapshot.albumArtist,
                    releaseYear: snapshot.releaseYear,
                    compilation: snapshot.compilation,
                    musicBrainzReleaseID: snapshot.musicBrainzReleaseID,
                    durationSeconds: snapshot.durationSeconds,
                    capturedAt: snapshot.capturedAt
                )
            },
            sourceMemberships: sourceMemberships,
            artistCredits: track.artistCredits.map {
                AutomationTrackCredit(
                    id: $0.id,
                    displayName: $0.displayName,
                    canonicalName: $0.canonicalName,
                    role: $0.role.rawValue
                )
            },
            albumArtist: track.albumArtist,
            userDescription: track.userDescription,
            genreTags: track.genreTags,
            language: track.language,
            labelOrCompany: track.labelOrCompany,
            releaseDate: track.releaseDate,
            qqMusicSongMid: track.qqMusicSongMid,
            metadataSource: track.metadataSource,
            metadataFetchedAt: track.metadataFetchedAt,
            metadataConfidence: track.metadataConfidence,
            musicBrainzReleaseID: track.musicBrainzReleaseID,
            lyricsTimeOffsetMs: track.lyricsTimeOffsetMs,
            lyricsStatus: trackLyricsStatus(track),
            artworkAvailable: track.hasArtwork,
            artworkFileName: track.artworkFileName,
            format: audio?.format,
            codec: audio?.codec,
            sampleRateHz: audio?.sampleRateHz,
            bitDepth: audio?.bitDepth,
            channelCount: audio?.channelCount,
            filePath: includeFilePath ? AutomationFileAccess.trackPath(track) : nil,
            playlistIDs: playlistIDs,
            preferenceStats: includePreferenceStats
                ? AutomationTrackPreferenceQuery.summary(preferenceStats ?? TrackPreferenceStats())
                : nil
        )
    }

    func makePlaylistSummary(_ playlist: Playlist) -> AutomationPlaylistSummary {
        let service = appSession?.activeLibraryBinding.activeSession?.libraryService
        let sidecar = service?.loadPlaylistSidecar(playlistID: playlist.id)
        let artworkSource = sidecar?.headerArtworkSource ?? .none
        let artworkFileName: String?
        switch artworkSource {
        case .custom:
            artworkFileName = sidecar?.customHeaderArtworkFileName
        case .generated:
            artworkFileName = sidecar?.generatedHeaderArtworkFileName
        case .none:
            artworkFileName = nil
        }
        return AutomationPlaylistSummary(
            id: playlist.id,
            name: playlist.name,
            description: playlist.userDescription,
            createdAt: playlist.createdAt,
            trackCount: playlist.trackCount,
            totalDuration: playlist.totalDuration,
            revision: appSession?.libraryVM?.automationPlaylistRevision(for: playlist) ?? "v1-0",
            artworkAvailable: artworkFileName != nil,
            artworkSource: artworkSource.rawValue,
            artworkFileName: artworkFileName,
            artworkRevision: sidecar?.artworkRevision
        )
    }

    func makeLibrarySummary(
        _ bookmark: MusicLibraryBookmark,
        activeLibraryID: UUID?
    ) -> AutomationLibrarySummary {
        AutomationLibrarySummary(
            id: bookmark.id,
            displayName: bookmark.displayName,
            mode: bookmark.modeProjection == .managed ? .managed : .referenced,
            isActive: bookmark.id == activeLibraryID
        )
    }

    func resolveTTMLText(for track: Track) -> String? {
        if let text = track.ttmlLyricText, !text.isEmpty {
            return text
        }
        if let text = track.loadTTMLLyricsIfNeeded(), !text.isEmpty {
            return text
        }
        if let fileName = track.ttmlLyricsFileName,
           let paths = appSession?.activeLibraryBinding.activeSession?.context.paths,
           let url = paths.trackAssetURL(for: track.id, fileName: fileName),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            track.ttmlLyricText = text
            return text
        }
        return nil
    }

    func resolvePlainLyricsText(for track: Track) -> String? {
        if let text = track.lyricsText, !text.isEmpty {
            return text
        }
        if let text = track.loadLyricsIfNeeded(), !text.isEmpty {
            return text
        }
        if let fileName = track.lyricsFileName,
           let paths = appSession?.activeLibraryBinding.activeSession?.context.paths,
           let url = paths.trackAssetURL(for: track.id, fileName: fileName),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            track.lyricsText = text
            return text
        }
        return nil
    }

    func currentLyricsQuality(_ track: Track) -> Int {
        if let ttml = resolveTTMLText(for: track),
           !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.isWordSyncedTTML(ttml) ? 2 : 1
        }
        if track.ttmlLyricsFileName != nil { return 1 }
        if let plain = resolvePlainLyricsText(for: track),
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.looksLikeLRC(plain) ? 1 : 0
        }
        return 0
    }

    func makeTrackRevisions(
        from values: [String: AutomationJSONValue]?
    ) throws -> [UUID: String] {
        guard let values else { return [:] }
        var result: [UUID: String] = [:]
        for (rawID, value) in values {
            guard let id = UUID(uuidString: rawID),
                  case .string(let revision) = value,
                  !revision.isEmpty else {
                throw AutomationParameterError.invalidValue("expectedRevisions")
            }
            result[id] = revision
        }
        return result
    }

    func makeMetadataDocumentTrack(_ track: Track, revision: String) -> AutomationMetadataDocumentTrack {
        func nullableString(_ value: String?) -> AutomationJSONValue {
            value.map(AutomationJSONValue.string) ?? .null
        }
        func nullableDate(_ value: Date?) -> AutomationJSONValue {
            value.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        }
        let fields: [String: AutomationJSONValue] = [
            "title": .string(track.title),
            "artist": .string(track.artist),
            "album": .string(track.album),
            "albumArtist": nullableString(track.albumArtist),
            "description": .string(track.userDescription),
            "genreTags": .array(track.genreTags.map(AutomationJSONValue.string)),
            "language": .string(track.language),
            "labelOrCompany": .string(track.labelOrCompany),
            "releaseDate": nullableDate(track.releaseDate),
            "qqMusicSongMid": nullableString(track.qqMusicSongMid),
            "metadataSource": nullableString(track.metadataSource),
            "metadataFetchedAt": nullableDate(track.metadataFetchedAt),
            "metadataConfidence": track.metadataConfidence.map(AutomationJSONValue.number) ?? .null,
            "musicBrainzReleaseID": nullableString(track.musicBrainzReleaseID),
            "lyricsTimeOffsetMs": .number(track.lyricsTimeOffsetMs),
            "artistCredits": .array(track.artistCredits.map { credit in
                .object([
                    "id": .string(credit.id.uuidString),
                    "displayName": .string(credit.displayName),
                    "canonicalName": nullableString(credit.canonicalName),
                    "role": .string(credit.role.rawValue)
                ])
            })
        ]
        return AutomationMetadataDocumentTrack(
            id: track.id,
            revision: revision,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            fields: fields
        )
    }
}
