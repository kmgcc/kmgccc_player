//
//  NowPlayingPresentation.swift
//  myPlayer2
//
//  Source-neutral playback state for UI presentation.
//

import Foundation

struct NowPlayingPresentation {
    var source: PlaybackSource
    var localTrack: Track?
    var title: String
    var artist: String
    var album: String?
    var artworkData: Data?
    var artworkIdentity: String?
    var isArtworkLoading: Bool
    var duration: Double
    var currentTime: Double
    var isPlaying: Bool
    var volume: Double
    var lyricsText: String?
    var lyricsIdentity: String?
    var appleMusicPlaybackMode: AppleMusicPlaybackMode?
    var externalStableKey: String?
    var externalRawTitle: String?
    var externalRawArtist: String?
    var externalRawAlbum: String?
    var externalEffectiveTitle: String?
    var externalEffectiveArtist: String?
    var externalEffectiveAlbum: String?
    var externalUsesOverride: Bool
    var externalMatchConfidence: Double?
    var externalLyricsStatusMessage: String?
    var isControlEnabled: Bool
    var isSeekEnabled: Bool
    var emptyTitleKey: String

    static let emptyLocal = NowPlayingPresentation(
        source: .local,
        localTrack: nil,
        title: "",
        artist: "",
        album: nil,
        artworkData: nil,
        artworkIdentity: nil,
        isArtworkLoading: false,
        duration: 0,
        currentTime: 0,
        isPlaying: false,
        volume: AppSettings.shared.volume,
        lyricsText: nil,
        lyricsIdentity: nil,
        appleMusicPlaybackMode: nil,
        externalStableKey: nil,
        externalRawTitle: nil,
        externalRawArtist: nil,
        externalRawAlbum: nil,
        externalEffectiveTitle: nil,
        externalEffectiveArtist: nil,
        externalEffectiveAlbum: nil,
        externalUsesOverride: false,
        externalMatchConfidence: nil,
        externalLyricsStatusMessage: nil,
        isControlEnabled: false,
        isSeekEnabled: false,
        emptyTitleKey: "mini.not_playing"
    )

    static let emptyAppleMusic = NowPlayingPresentation(
        source: .appleMusic,
        localTrack: nil,
        title: "",
        artist: "",
        album: nil,
        artworkData: nil,
        artworkIdentity: nil,
        isArtworkLoading: false,
        duration: 0,
        currentTime: 0,
        isPlaying: false,
        volume: 1,
        lyricsText: nil,
        lyricsIdentity: nil,
        appleMusicPlaybackMode: nil,
        externalStableKey: nil,
        externalRawTitle: nil,
        externalRawArtist: nil,
        externalRawAlbum: nil,
        externalEffectiveTitle: nil,
        externalEffectiveArtist: nil,
        externalEffectiveAlbum: nil,
        externalUsesOverride: false,
        externalMatchConfidence: nil,
        externalLyricsStatusMessage: nil,
        isControlEnabled: false,
        isSeekEnabled: false,
        emptyTitleKey: "apple_music.not_running"
    )

    var hasTrack: Bool {
        localTrack != nil || !title.isEmpty
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }
}

extension NowPlayingPresentation {
    /// Compares fields that affect UI rendering, skipping expensive Data comparison.
    /// Artwork is assumed stable when track identity (lyricsIdentity / localTrack) is unchanged.
    func isEffectivelyEqual(to other: NowPlayingPresentation) -> Bool {
        source == other.source &&
        title == other.title &&
        artist == other.artist &&
        album == other.album &&
        artworkIdentity == other.artworkIdentity &&
        isArtworkLoading == other.isArtworkLoading &&
        duration == other.duration &&
        currentTime == other.currentTime &&
        isPlaying == other.isPlaying &&
        volume == other.volume &&
        lyricsIdentity == other.lyricsIdentity &&
        lyricsText == other.lyricsText &&
        appleMusicPlaybackMode == other.appleMusicPlaybackMode &&
        externalStableKey == other.externalStableKey &&
        externalRawTitle == other.externalRawTitle &&
        externalRawArtist == other.externalRawArtist &&
        externalRawAlbum == other.externalRawAlbum &&
        externalEffectiveTitle == other.externalEffectiveTitle &&
        externalEffectiveArtist == other.externalEffectiveArtist &&
        externalEffectiveAlbum == other.externalEffectiveAlbum &&
        externalUsesOverride == other.externalUsesOverride &&
        externalMatchConfidence == other.externalMatchConfidence &&
        externalLyricsStatusMessage == other.externalLyricsStatusMessage &&
        isControlEnabled == other.isControlEnabled &&
        isSeekEnabled == other.isSeekEnabled &&
        emptyTitleKey == other.emptyTitleKey
    }
}
