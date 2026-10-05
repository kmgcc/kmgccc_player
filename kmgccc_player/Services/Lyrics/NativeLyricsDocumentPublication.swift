import Observation

/// Only document/configuration changes notify custom lyric readers. Playback time
/// continues to come from the existing presentation clock.
@Observable
@MainActor
final class NativeLyricsDocumentPublication {
    private(set) var revision: UInt64 = 0
    func changed() { revision &+= 1 }
}
