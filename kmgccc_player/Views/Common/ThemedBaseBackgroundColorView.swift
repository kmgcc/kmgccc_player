//
//  ThemedBaseBackgroundColorView.swift
//  myPlayer2
//
//  Created by Antigravity on 2026-06-10.
//  A reusable background view that applies the theme-dependent base color
//  drawn from the home page background.
//

import SwiftUI

struct ThemedBaseBackgroundColorView: View {
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        let baseColor = HomeAmbientPalette.ambientBaseColor(
            from: themeStore.semanticPalette.ambientSurface,
            analysis: themeStore.semanticPalette.analysis,
            colorScheme: themeStore.colorScheme
        )
        ColorRenderingAdapter.makeSwiftUIColor(baseColor)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.20), value: baseColor)
    }
}
