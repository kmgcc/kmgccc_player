//
//  PlaylistDetailSessionController.swift
//  myPlayer2
//
//  Page-scoped runtime session state for playlist detail.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class PlaylistDetailSessionController: ObservableObject {
    @Published var areRowSecondaryInteractionsEnabled = false
    @Published var areRowArtworkLoadsEnabled = true
    @Published var isRowArtworkPrefetchEnabled = false
    @Published var isHeaderEffectsEnabled = false

    private var phaseToken = UUID()

    func activateFirstPaintPhases(for selection: LibrarySelection) {
        let token = UUID()
        phaseToken = token
        areRowSecondaryInteractionsEnabled = false
        areRowArtworkLoadsEnabled = true
        isRowArtworkPrefetchEnabled = false
        isHeaderEffectsEnabled = selection == .allSongs

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard phaseToken == token else { return }
            areRowSecondaryInteractionsEnabled = true
            isRowArtworkPrefetchEnabled = true
        }

        guard selection != .allSongs else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 270_000_000)
            guard phaseToken == token else { return }
            isHeaderEffectsEnabled = true
        }
    }

    func beginTeardown() {
        phaseToken = UUID()
        areRowSecondaryInteractionsEnabled = false
        areRowArtworkLoadsEnabled = false
        isRowArtworkPrefetchEnabled = false
        isHeaderEffectsEnabled = false
    }

    func cancelPhases() {
        phaseToken = UUID()
        areRowSecondaryInteractionsEnabled = false
        areRowArtworkLoadsEnabled = false
        isRowArtworkPrefetchEnabled = false
        isHeaderEffectsEnabled = false
    }
}
