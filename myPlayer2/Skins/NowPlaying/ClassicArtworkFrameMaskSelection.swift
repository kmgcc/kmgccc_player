//
//  ClassicArtworkFrameMaskSelection.swift
//  myPlayer2
//
//  Stable per-track artwork frame selection for the classic skin.
//

import Foundation

struct ClassicArtworkFrameMaskKey: Equatable {
    let id: UUID
    let title: String
    let artist: String
    let album: String

    init?(track: SkinContext.TrackMetadata?) {
        guard let track else { return nil }
        self.id = track.id
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
    }
}

final class ClassicArtworkFrameMaskSelection: @unchecked Sendable {
    static let shared = ClassicArtworkFrameMaskSelection()

    private let lock = NSLock()
    private var currentKey: ClassicArtworkFrameMaskKey?
    private var currentIndex: Int?

    private init() {}

    func maskIndex(for key: ClassicArtworkFrameMaskKey?, frameCount: Int) -> Int? {
        guard frameCount > 0, let key else {
            clearSelection()
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        if currentKey == key, let currentIndex, currentIndex < frameCount {
            return currentIndex
        }

        let nextIndex = Int.random(in: 0..<frameCount)
        currentKey = key
        currentIndex = nextIndex
        return nextIndex
    }

    func advanceMask(for key: ClassicArtworkFrameMaskKey?, frameCount: Int) -> Int? {
        guard frameCount > 0, let key else {
            clearSelection()
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        let nextIndex: Int
        if currentKey == key, let currentIndex, currentIndex < frameCount {
            nextIndex = frameCount > 1 ? (currentIndex + 1) % frameCount : currentIndex
        } else {
            nextIndex = Int.random(in: 0..<frameCount)
        }

        currentKey = key
        currentIndex = nextIndex
        return nextIndex
    }

    private func clearSelection() {
        lock.lock()
        defer { lock.unlock() }
        currentKey = nil
        currentIndex = nil
    }
}
