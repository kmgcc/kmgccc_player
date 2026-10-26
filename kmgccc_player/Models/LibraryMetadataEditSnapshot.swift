import Foundation

/// Captured immediately before a deliberate edit; media hydration and automatic
/// enrichment do not create manual ownership merely by saving a sidecar.
nonisolated struct LibraryMetadataEditSnapshot {
    private let values: [String: AnyHashable]

    init(_ value: Track) {
        values = [
            "title": AnyHashable(value.title),
            "artist": AnyHashable(value.artist),
            "album": AnyHashable(value.album),
            "albumArtist": AnyHashable(value.albumArtist),
            "artistCredits": AnyHashable(value.artistCredits),
            "description": AnyHashable(value.userDescription),
            "genreTags": AnyHashable(value.genreTags),
            "language": AnyHashable(value.language),
            "labelOrCompany": AnyHashable(value.labelOrCompany),
            "releaseDate": AnyHashable(value.releaseDate),
            "qqMusicSongMid": AnyHashable(value.qqMusicSongMid),
            "metadataSource": AnyHashable(value.metadataSource),
            "metadataFetchedAt": AnyHashable(value.metadataFetchedAt),
            "metadataConfidence": AnyHashable(value.metadataConfidence),
            "musicBrainzReleaseID": AnyHashable(value.musicBrainzReleaseID),
            "lyricsTimeOffsetMs": AnyHashable(value.lyricsTimeOffsetMs),
        ]
    }

    init(_ value: ArtistEntry) {
        values = [
            "displayName": AnyHashable(value.displayName),
            "description": AnyHashable(value.description),
            "genreTags": AnyHashable(value.genreTags),
            "region": AnyHashable(value.region),
            "foreignName": AnyHashable(value.foreignName),
            "qqMusicSingerMid": AnyHashable(value.qqMusicSingerMid),
            "metadataSource": AnyHashable(value.metadataSource),
            "metadataFetchedAt": AnyHashable(value.metadataFetchedAt),
            "metadataConfidence": AnyHashable(value.metadataConfidence),
        ]
    }

    init(_ value: AlbumEntry) {
        values = [
            "displayTitle": AnyHashable(value.displayTitle),
            "primaryArtistDisplayName": AnyHashable(value.primaryArtistDisplayName),
            "description": AnyHashable(value.description),
            "year": AnyHashable(value.year),
            "releaseYear": AnyHashable(value.releaseYear),
            "releaseDate": AnyHashable(value.releaseDate),
            "albumType": AnyHashable(value.albumType),
            "genreTags": AnyHashable(value.genreTags),
            "language": AnyHashable(value.language),
            "labelOrCompany": AnyHashable(value.labelOrCompany),
            "qqMusicAlbumMid": AnyHashable(value.qqMusicAlbumMid),
            "metadataSource": AnyHashable(value.metadataSource),
            "metadataFetchedAt": AnyHashable(value.metadataFetchedAt),
            "metadataConfidence": AnyHashable(value.metadataConfidence),
            "loudnessUnified": AnyHashable(value.loudnessUnifiedOverride),
        ]
    }

    func changedFields(since original: Self) -> Set<String> {
        Set(values.keys.filter { values[$0] != original.values[$0] })
    }
}

extension UserMetadataOverride {
    /// Older sidecars already store explicit corrections without field flags.
    nonisolated var protectedFields: Set<String> {
        var fields = manuallyEditedFields ?? []
        if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { fields.insert("title") }
        if artistDisplay?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { fields.insert("artist") }
        if album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { fields.insert("album") }
        if albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { fields.insert("albumArtist") }
        if albumGroupKey != nil { fields.insert("album") }
        if releaseYear != nil { fields.insert("releaseYear") }
        return fields
    }
}

extension Track {
    nonisolated func isMetadataFieldManual(_ field: String) -> Bool {
        userMetadataOverride?.protectedFields.contains(field) == true
    }

    nonisolated var allowsAutomaticLyrics: Bool { !isMetadataFieldManual("lyrics") }

    nonisolated func markMetadataFieldsAsManual(_ fields: Set<String>) {
        guard !fields.isEmpty else { return }
        var correction = userMetadataOverride ?? UserMetadataOverride(editedAt: Date())
        correction.manuallyEditedFields = correction.protectedFields.union(fields)
        if fields.contains("title") { correction.title = title }
        if fields.contains("artist") { correction.artistDisplay = artist }
        if fields.contains("album") { correction.album = album }
        if fields.contains("albumArtist") { correction.albumArtist = albumArtist }
        correction.editedAt = Date()
        userMetadataOverride = correction
    }

    nonisolated func recordManualMetadataEdits(since original: LibraryMetadataEditSnapshot) {
        let fields = LibraryMetadataEditSnapshot(self).changedFields(since: original)
        if fields.contains("album"), var correction = userMetadataOverride {
            correction.albumGroupKey = nil
            userMetadataOverride = correction
        }
        markMetadataFieldsAsManual(fields)
    }
}

extension ArtistEntry {
    mutating func recordManualMetadataEdits(since original: ArtistEntry) {
        manuallyEditedFields.formUnion(original.manuallyEditedFields)
        manuallyEditedFields.formUnion(
            LibraryMetadataEditSnapshot(self).changedFields(since: LibraryMetadataEditSnapshot(original))
        )
    }
}

extension AlbumEntry {
    mutating func recordManualMetadataEdits(since original: AlbumEntry) {
        manuallyEditedFields.formUnion(original.manuallyEditedFields)
        manuallyEditedFields.formUnion(
            LibraryMetadataEditSnapshot(self).changedFields(since: LibraryMetadataEditSnapshot(original))
        )
    }
}

extension ArtistEntry {
    /// Keep deliberate values when duplicate or renamed entries are merged.
    func preservingManualMetadata(from candidates: [Self]) -> Self {
        var updated = self
        let ordered = candidates.sorted { $0.updatedAt > $1.updatedAt }
        func preserve<Value>(_ field: String, _ keyPath: WritableKeyPath<Self, Value>) {
            if let source = ordered.first(where: { $0.manuallyEditedFields.contains(field) }) {
                updated[keyPath: keyPath] = source[keyPath: keyPath]
            }
        }
        preserve("displayName", \.displayName)
        preserve("description", \.description)
        preserve("genreTags", \.genreTags)
        preserve("region", \.region)
        preserve("foreignName", \.foreignName)
        preserve("qqMusicSingerMid", \.qqMusicSingerMid)
        preserve("metadataSource", \.metadataSource)
        preserve("metadataFetchedAt", \.metadataFetchedAt)
        preserve("metadataConfidence", \.metadataConfidence)
        for candidate in candidates { updated.manuallyEditedFields.formUnion(candidate.manuallyEditedFields) }
        return updated
    }
}

extension AlbumEntry {
    /// Keep deliberate values when duplicate or renamed entries are merged.
    func preservingManualMetadata(from candidates: [Self]) -> Self {
        var updated = self
        let ordered = candidates.sorted { $0.updatedAt > $1.updatedAt }
        func preserve<Value>(_ field: String, _ keyPath: WritableKeyPath<Self, Value>) {
            if let source = ordered.first(where: { $0.manuallyEditedFields.contains(field) }) {
                updated[keyPath: keyPath] = source[keyPath: keyPath]
            }
        }
        preserve("displayTitle", \.displayTitle)
        preserve("primaryArtistDisplayName", \.primaryArtistDisplayName)
        preserve("year", \.year)
        preserve("releaseYear", \.releaseYear)
        preserve("releaseDate", \.releaseDate)
        preserve("description", \.description)
        preserve("albumType", \.albumType)
        preserve("genreTags", \.genreTags)
        preserve("language", \.language)
        preserve("labelOrCompany", \.labelOrCompany)
        preserve("qqMusicAlbumMid", \.qqMusicAlbumMid)
        preserve("metadataSource", \.metadataSource)
        preserve("metadataFetchedAt", \.metadataFetchedAt)
        preserve("metadataConfidence", \.metadataConfidence)
        preserve("loudnessUnified", \.loudnessUnifiedOverride)
        for candidate in candidates { updated.manuallyEditedFields.formUnion(candidate.manuallyEditedFields) }
        return updated
    }
}

extension ArtistSidecar {
    /// Keep deliberate values when duplicate or renamed entries are merged.
    func preservingManualMetadata(from candidates: [Self]) -> Self {
        var updated = self
        let ordered = candidates.sorted { $0.updatedAt > $1.updatedAt }
        func preserve<Value>(_ field: String, _ keyPath: WritableKeyPath<Self, Value>) {
            if let source = ordered.first(where: { $0.manuallyEditedFields.contains(field) }) {
                updated[keyPath: keyPath] = source[keyPath: keyPath]
            }
        }
        preserve("displayName", \.displayName)
        preserve("description", \.description)
        preserve("genreTags", \.genreTags)
        preserve("region", \.region)
        preserve("foreignName", \.foreignName)
        preserve("qqMusicSingerMid", \.qqMusicSingerMid)
        preserve("metadataSource", \.metadataSource)
        preserve("metadataFetchedAt", \.metadataFetchedAt)
        preserve("metadataConfidence", \.metadataConfidence)
        for candidate in candidates { updated.manuallyEditedFields.formUnion(candidate.manuallyEditedFields) }
        return updated
    }
}

extension AlbumSidecar {
    /// Keep deliberate values when duplicate or renamed entries are merged.
    func preservingManualMetadata(from candidates: [Self]) -> Self {
        var updated = self
        let ordered = candidates.sorted { $0.updatedAt > $1.updatedAt }
        func preserve<Value>(_ field: String, _ keyPath: WritableKeyPath<Self, Value>) {
            if let source = ordered.first(where: { $0.manuallyEditedFields.contains(field) }) {
                updated[keyPath: keyPath] = source[keyPath: keyPath]
            }
        }
        preserve("displayTitle", \.displayTitle)
        preserve("primaryArtistDisplayName", \.primaryArtistDisplayName)
        preserve("year", \.year)
        preserve("releaseYear", \.releaseYear)
        preserve("releaseDate", \.releaseDate)
        preserve("description", \.description)
        preserve("albumType", \.albumType)
        preserve("genreTags", \.genreTags)
        preserve("language", \.language)
        preserve("labelOrCompany", \.labelOrCompany)
        preserve("qqMusicAlbumMid", \.qqMusicAlbumMid)
        preserve("metadataSource", \.metadataSource)
        preserve("metadataFetchedAt", \.metadataFetchedAt)
        preserve("metadataConfidence", \.metadataConfidence)
        preserve("loudnessUnified", \.loudnessUnified)
        for candidate in candidates { updated.manuallyEditedFields.formUnion(candidate.manuallyEditedFields) }
        return updated
    }
}
