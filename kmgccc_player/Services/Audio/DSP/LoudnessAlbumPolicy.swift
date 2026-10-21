import Foundation

/// Why an album group is not normalized as one unit by default.
nonisolated enum LoudnessAlbumExclusion: String, Codable, Equatable, Sendable {
    case unreliableAlbumName
    case unreliableArtist
    case compilation
    case mixedSources
    case scatteredArtists

    /// One line shown in the album editor under the unify switch.
    nonisolated var message: String {
        switch self {
        case .unreliableAlbumName: "专辑名称未知，默认逐首调整音量。"
        case .unreliableArtist: "专辑艺人未知，默认逐首调整音量。"
        case .compilation: "这是一张合辑，默认逐首调整音量。"
        case .mixedSources: "曲目的音频格式不一致，默认逐首调整音量。"
        case .scatteredArtists: "曲目来自多位艺人，默认逐首调整音量。"
        }
    }
}

/// The facts the album judgement needs from one library track.
nonisolated struct LoudnessAlbumMember: Equatable, Sendable {
    var trackID: UUID
    var album: String
    var albumArtist: String?
    var artist: String
    var codec: String?
    var sampleRateHz: Int?
}

nonisolated struct LoudnessAlbumJudgement: Equatable, Sendable {
    var albumKey: String
    var memberIDs: [UUID]
    /// Nil when the automatic rules accept the group as a real album.
    var automaticExclusion: LoudnessAlbumExclusion?
    /// The per-album switch: true forces one gain, false forces per track.
    var override: Bool?

    nonisolated var automaticallyUnifies: Bool { automaticExclusion == nil }
    nonisolated var unifies: Bool { override ?? automaticallyUnifies }
}

/// Decides whether an album group shares one normalization gain. The rules
/// prefer a false exclusion over joining unrelated recordings: an excluded
/// album is still normalized track by track, while a wrongly joined group
/// would give a song a gain derived from other music.
nonisolated enum LoudnessAlbumPolicy {
    /// Placeholder names that only this judgement treats as unknown. They are
    /// deliberately not added to library grouping or display.
    nonisolated static let extraPlaceholderAlbumNames: Set<String> = [
        "未知", "unknown", "<unknown>", "n/a", "none", "null", "untitled", "未命名", "无",
    ]

    nonisolated static let unknownArtistNames: Set<String> = [
        "未知歌手", "未知艺人", "未知艺术家", "未知", "unknown", "unknown artist", "<unknown>",
    ]

    nonisolated static func judge(
        albumKey: String,
        albumType: String?,
        members: [LoudnessAlbumMember],
        override: Bool?
    ) -> LoudnessAlbumJudgement {
        LoudnessAlbumJudgement(
            albumKey: albumKey,
            memberIDs: members.map(\.trackID),
            automaticExclusion: automaticExclusion(albumType: albumType, members: members),
            override: override
        )
    }

    nonisolated static func automaticExclusion(
        albumType: String?,
        members: [LoudnessAlbumMember]
    ) -> LoudnessAlbumExclusion? {
        guard !members.isEmpty else { return .unreliableAlbumName }

        // 1. Album name.
        if members.contains(where: { isUnreliableAlbumName($0.album) }) {
            return .unreliableAlbumName
        }

        // 2. Album artist, or every track artist when none is tagged.
        let albumArtists = members.compactMap { member -> String? in
            let value = member.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let artistCredits = albumArtists.isEmpty ? members.map(\.artist) : albumArtists
        if artistCredits.contains(where: containsUnknownArtist) {
            return .unreliableArtist
        }

        // 3. Compilations usually collect differently mastered recordings.
        if LibraryNormalization.isCompilationAlbumType(albumType, primaryArtist: albumArtists.first)
            || albumArtists.contains(where: { LibraryNormalization.isCompilationAlbumType(nil, primaryArtist: $0) }) {
            return .compilation
        }

        // 4. Mixed codecs or sample rates suggest a group assembled from
        //    different sources.
        let codecs = Set(members.compactMap { $0.codec.map(normalizedCodec) }.filter { !$0.isEmpty })
        let sampleRates = Set(members.compactMap(\.sampleRateHz).filter { $0 > 0 })
        if codecs.count > 1 || sampleRates.count > 1 {
            return .mixedSources
        }

        // 5. Without an album artist, three or more lead artists suggest that
        //    same-named albums were grouped together.
        if albumArtists.isEmpty {
            let leads = Set(members.compactMap {
                LibraryNormalization.artistComponents($0.artist).first?.canonicalName
            })
            if leads.count >= 3 { return .scatteredArtists }
        }
        return nil
    }

    nonisolated static func isUnreliableAlbumName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || LibraryNormalization.isPlaceholderAlbumTitle(trimmed) { return true }
        if extraPlaceholderAlbumNames.contains(trimmed.lowercased()) { return true }
        let meaningful = trimmed.unicodeScalars.contains {
            CharacterSet.letters.contains($0)
        }
        return !meaningful
    }

    nonisolated static func containsUnknownArtist(_ credit: String) -> Bool {
        let trimmed = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Reliability may inspect collaborators without changing the library's
        // grouping contract, which preserves names such as "Simon & Garfunkel".
        let parts = LibraryNormalization.artistDisplayNameParts(trimmed)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "&＆")) }
        guard !parts.isEmpty else { return true }
        return parts.contains { unknownArtistNames.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    private nonisolated static func normalizedCodec(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowered {
        case "m4a", "mp4", "aac", "mp4a", "aac-lc": return "aac"
        case "aif", "aiff", "aifc": return "aiff"
        case "wav", "wave", "lpcm", "pcm": return "pcm"
        default: return lowered
        }
    }
}
