//
//  NowPlayingSkin.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Skin Protocol
//

import SwiftUI

protocol NowPlayingSkin {
    var id: String { get }
    var name: String { get }
    var detail: String { get }
    var systemImage: String { get }
    var isFullscreenCompatible: Bool { get }
    var isNowPlayingCompatible: Bool { get }

    func makeBackground(context: SkinContext) -> AnyView
    func makeArtwork(context: SkinContext) -> AnyView
    func makeOverlay(context: SkinContext) -> AnyView?
    
    /// Settings view for normal (now playing) mode
    var settingsView: AnyView? { get }
    /// Settings view for fullscreen mode (independent from normal mode)
    var fullscreenSettingsView: AnyView? { get }
}

extension NowPlayingSkin {
    func makeOverlay(context: SkinContext) -> AnyView? {
        nil
    }

    var settingsView: AnyView? {
        nil
    }

    var fullscreenSettingsView: AnyView? {
        nil
    }
}
