//
//  SkinTheme.swift
//  myPlayer2
//
//  Split skin protocols by presentation mode.
//

import SwiftUI

protocol NormalSkin {
    func makeBackground(context: SkinContext) -> AnyView
    func makeArtwork(context: SkinContext) -> AnyView
    func makeOverlay(context: SkinContext) -> AnyView?
    func makeSettingsView() -> AnyView?

    var artBackgroundResourceProfile: BKArtBackgroundView.ResourceProfile { get }
    var allowsHostArtBackground: Bool { get }
}

extension NormalSkin {
    func makeOverlay(context: SkinContext) -> AnyView? {
        nil
    }

    func makeSettingsView() -> AnyView? {
        nil
    }

    var artBackgroundResourceProfile: BKArtBackgroundView.ResourceProfile { .standard }
    var allowsHostArtBackground: Bool { true }
}

protocol FullscreenSkin {
    func makeBackground(context: SkinContext) -> AnyView
    func makeArtwork(context: SkinContext) -> AnyView
    func makeOverlay(context: SkinContext) -> AnyView?
    func makeSettingsView(actions: SkinHostActions) -> AnyView?

    var wantsCoverBlurLyricsTreatment: Bool { get }
    var hasMiniPlayerMotion: Bool { get }
    var artBackgroundResourceProfile: BKArtBackgroundView.ResourceProfile { get }
    var allowsHostArtBackground: Bool { get }
}

extension FullscreenSkin {
    func makeOverlay(context: SkinContext) -> AnyView? {
        nil
    }

    func makeSettingsView(actions: SkinHostActions) -> AnyView? {
        nil
    }

    var wantsCoverBlurLyricsTreatment: Bool { false }
    var hasMiniPlayerMotion: Bool { false }
    var artBackgroundResourceProfile: BKArtBackgroundView.ResourceProfile { .standard }
    var allowsHostArtBackground: Bool { true }
}

protocol SkinTheme {
    var id: String { get }
    var name: String { get }
    var detail: String { get }
    var systemImage: String { get }

    var normal: (any NormalSkin)? { get }
    var fullscreen: (any FullscreenSkin)? { get }
}
