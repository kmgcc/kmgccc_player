//
//  FullscreenArtworkLoader.swift
//  myPlayer2
//

import Foundation

enum FullscreenArtworkLoader {
    @MainActor
    static func loadSnapshot(
        track: Track?,
        currentTaskKey: String,
        preferredFullImageMaxPixel: Int,
        currentTrackID: @escaping @MainActor () -> UUID?,
        currentTaskKeyProvider: @escaping @MainActor () -> String
    ) async -> ArtworkAssetSnapshot? {
        guard let track, let artworkData = track.artworkData, !artworkData.isEmpty else {
            return nil
        }

        let expectedTrackID = track.id
        let snapshot = await ArtworkAssetStore.shared.snapshot(
            trackID: track.id,
            artworkData: artworkData,
            fullImageMaxPixelSize: preferredFullImageMaxPixel
        )
        guard !Task.isCancelled else { return nil }
        guard currentTrackID() == expectedTrackID else { return nil }
        guard currentTaskKeyProvider() == currentTaskKey else { return nil }
        guard snapshot?.trackID == expectedTrackID else { return nil }
        return snapshot
    }
}
