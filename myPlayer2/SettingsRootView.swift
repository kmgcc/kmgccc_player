//
//  SettingsRootView.swift
//  myPlayer2
//
//  kmgccc_player - Settings Scene Root View with Environment Setup
//

import SwiftUI

struct SettingsRootView: View {
    @StateObject private var themeStore = ThemeStore.shared
    @State private var settings = AppSettings.shared
    @ObservedObject private var sharedState = SharedAppState.shared

    var body: some View {
        if let libraryVM = sharedState.libraryVM,
           let playerVM = sharedState.playerVM,
           let lyricsVM = sharedState.lyricsVM,
           let ledMeter = sharedState.ledMeter
        {
            SettingsView()
                .environment(settings)
                .environment(libraryVM)
                .environment(playerVM)
                .environment(lyricsVM)
                .environment(ledMeter)
                .environmentObject(themeStore)
        } else {
            VStack(spacing: 16) {
                ProgressView()
                Text("加载设置中...")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 400, height: 200)
        }
    }
}