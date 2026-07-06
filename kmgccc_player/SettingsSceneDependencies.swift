//
//  SettingsSceneDependencies.swift
//  myPlayer2
//
//  kmgccc_player - Shared dependencies for the Settings scene
//

import Combine

@MainActor
final class SettingsSceneDependencies: ObservableObject {
    @Published var libraryVM: LibraryViewModel?
    @Published var playerVM: PlayerViewModel?
    @Published var playbackCoordinator: PlaybackCoordinator?
    @Published var lyricsVM: LyricsViewModel?
    @Published var ledMeterProvider: LEDMeterServiceProvider?

    func configure(
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel,
        playbackCoordinator: PlaybackCoordinator,
        lyricsVM: LyricsViewModel,
        ledMeterProvider: LEDMeterServiceProvider
    ) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.playbackCoordinator = playbackCoordinator
        self.lyricsVM = lyricsVM
        self.ledMeterProvider = ledMeterProvider
    }
}
