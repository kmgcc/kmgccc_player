//
//  NowPlayingDisplayContext.swift
//  myPlayer2
//
//  Stable display-facing projection of source-neutral playback state.
//

import Foundation

struct NowPlayingDisplayContext: Equatable {
    var source: PlaybackSource
    var trackID: UUID?
    var hasTrack: Bool
    var title: String
    var artist: String
    var album: String?
    var artworkData: Data?
    var artworkIdentity: String?
    var isArtworkLoading: Bool
    var lyricsText: String?
    var lyricsIdentity: String?
    var duration: Double
    var currentTime: Double
    var isPlaying: Bool
}

extension NowPlayingPresentation {
    var displayContext: NowPlayingDisplayContext {
        NowPlayingDisplayContext(
            source: source,
            trackID: displayTrackID,
            hasTrack: hasTrack,
            title: title,
            artist: artist,
            album: album,
            artworkData: artworkData,
            artworkIdentity: artworkIdentity,
            isArtworkLoading: isArtworkLoading,
            lyricsText: lyricsText,
            lyricsIdentity: lyricsIdentity,
            duration: duration,
            currentTime: currentTime,
            isPlaying: isPlaying
        )
    }

    var displayTrackID: UUID? {
        if let id = localTrack?.id {
            return id
        }
        guard source != .local, hasTrack else { return nil }
        return Self.externalDisplayUUID(for: externalStableKey ?? lyricsIdentity ?? "\(title)|\(artist)|\(duration)")
    }

    private static func externalDisplayUUID(for key: String) -> UUID {
        let bytes = fnv128Bytes(for: key)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func fnv128Bytes(for key: String) -> [UInt8] {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in key.utf8 {
            first ^= UInt64(byte)
            first &*= 0x0000_0100_0000_01B3
            second ^= UInt64(byte).byteSwapped
            second &*= 0x0000_0100_0000_01B3
        }
        return withUnsafeBytes(of: first.bigEndian, Array.init)
            + withUnsafeBytes(of: second.bigEndian, Array.init)
    }
}
