//
//  SharedAppState.swift
//  myPlayer2
//
//  kmgccc_player - Shared App State for Settings Scene
//

import Combine
import SwiftUI

@MainActor
final class SharedAppState: ObservableObject {
    static let shared = SharedAppState()

    @Published var libraryVM: LibraryViewModel?
    @Published var playerVM: PlayerViewModel?
    @Published var lyricsVM: LyricsViewModel?
    @Published var ledMeter: LEDMeterService?
    @Published var skinManager: SkinManager?
    @Published var themeStore: ThemeStore?

    func configure(
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel,
        lyricsVM: LyricsViewModel,
        ledMeter: LEDMeterService,
        skinManager: SkinManager,
        themeStore: ThemeStore
    ) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.lyricsVM = lyricsVM
        self.ledMeter = ledMeter
        self.skinManager = skinManager
        self.themeStore = themeStore
    }
}