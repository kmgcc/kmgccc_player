//
//  SettingsRootView.swift
//  myPlayer2
//
//  kmgccc_player - Settings Scene Root View with Environment Setup
//

import SwiftUI

struct SettingsRootView: View {
    let libraryVM: LibraryViewModel
    let playerVM: PlayerViewModel
    let lyricsVM: LyricsViewModel
    let ledMeterProvider: LEDMeterServiceProvider

    @StateObject private var themeStore = ThemeStore.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsView()
            .environment(settings)
            .environment(libraryVM)
            .environment(playerVM)
            .environment(lyricsVM)
            .environment(ledMeterProvider)
            .environmentObject(themeStore)
    }
}
