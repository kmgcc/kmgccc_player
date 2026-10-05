//
//  NowPlayingSkin.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Skin Protocol
//

import SwiftUI

protocol NowPlayingSkin {
    var descriptor: SkinDescriptor { get }
    var scene: SkinScene? { get }
    var parameterDefinitions: [SkinParameterDefinition] { get }

    func makeBackground(context: SkinContext) -> AnyView
    func makeArtwork(context: SkinContext) -> AnyView
    func makeOverlay(context: SkinContext) -> AnyView?
    
    /// Settings view for normal (now playing) mode
    var settingsView: AnyView? { get }
    /// Settings view for fullscreen mode (independent from normal mode)
    var fullscreenSettingsView: AnyView? { get }

    func releaseCachedResources() async
}

extension NowPlayingSkin {
    var scene: SkinScene? { nil }
    var parameterDefinitions: [SkinParameterDefinition] { [] }
    var id: String { descriptor.id }
    var name: String { descriptor.name }
    var detail: String { descriptor.detail }
    var systemImage: String { descriptor.systemImage }
    var isFullscreenCompatible: Bool { descriptor.surfaces.contains(.fullscreen) }
    var isNowPlayingCompatible: Bool { descriptor.surfaces.contains(.window) }

    func releaseCachedResources() async {}

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(SkinArtworkComponent(snapshot: .init(context: context)))
    }

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
