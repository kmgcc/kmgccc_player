//
//  HomeDebugFlags.swift
//  myPlayer2
//
//  UserDefaults-backed flags to A/B test individual Home sections during
//  performance investigation. None of these are exposed in Settings UI;
//  flip them from a terminal and relaunch the app:
//
//    defaults write kmgccc.player home.debug.disableAmbient -bool YES
//    defaults write kmgccc.player home.debug.disableHero -bool YES
//    defaults write kmgccc.player home.debug.disablePlaylists -bool YES
//    defaults write kmgccc.player home.debug.disableArtists -bool YES
//    defaults write kmgccc.player home.debug.disableAlbums -bool YES
//    defaults write kmgccc.player home.debug.disableInsights -bool YES
//
//  ... or unset with:
//    defaults delete kmgccc.player home.debug.disableAmbient
//
//  Use these to narrow down which section is responsible for residual
//  scroll / resize jank, then optimize that section structurally rather
//  than continuing to micro-tune layout buckets.
//

import Foundation

enum HomeDebugFlags {
    static var disableAmbient: Bool {
        UserDefaults.standard.bool(forKey: "home.debug.disableAmbient")
    }

    static var disableHero: Bool {
        UserDefaults.standard.bool(forKey: "home.debug.disableHero")
    }

    static var disablePlaylists: Bool {
        UserDefaults.standard.bool(forKey: "home.debug.disablePlaylists")
    }

    static var disableArtists: Bool {
        UserDefaults.standard.bool(forKey: "home.debug.disableArtists")
    }

    static var disableAlbums: Bool {
        UserDefaults.standard.bool(forKey: "home.debug.disableAlbums")
    }

    static var disableInsights: Bool {
        UserDefaults.standard.bool(forKey: "home.debug.disableInsights")
    }
}
