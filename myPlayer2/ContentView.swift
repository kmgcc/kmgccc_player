//
//  ContentView.swift
//  myPlayer2
//
//  kmgccc_player - Legacy Content View
//  This file is kept for compatibility but AppRootView is the main entry.
//

import SwiftData
import SwiftUI

/// Legacy ContentView - redirects to AppRootView.
/// Kept for compatibility with existing project structure.
struct ContentView: View {
    @StateObject private var appSession: AppSessionHost

    init() {
        let settingsSceneDependencies = SettingsSceneDependencies()
        let sharedModelContainer: ModelContainer = {
            let schema = Schema([
                TrackIndexEntry.self
            ])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create preview ModelContainer: \(error)")
            }
        }()

        _appSession = StateObject(
            wrappedValue: AppSessionHost(
                modelContainer: sharedModelContainer,
                settingsSceneDependencies: settingsSceneDependencies
            )
        )
    }

    var body: some View {
        AppRootView(appSession: appSession)
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
