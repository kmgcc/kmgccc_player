//
//  ContentView.swift
//  myPlayer2
//
//  kmgccc_player - Legacy Content View
//  This file is kept for compatibility but AppRootView is the main entry.
//

import SwiftUI

/// Legacy ContentView - redirects to AppRootView.
/// Kept for compatibility with existing project structure.
struct ContentView: View {
    var body: some View {
        AppRootView()
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
