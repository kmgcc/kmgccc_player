//
//  SkinRegistry.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Skin Registry
//

import Foundation
import SwiftUI

struct SkinOption: Identifiable {
    let id: String
    let name: String
    let detail: String
    let systemImage: String
}

enum SkinRegistry {

    static let skins: [any NowPlayingSkin] = [
        ClassicLEDSkin(),
        RotatingCoverSkin(),
        KmgcccCassetteSkin(),
        FullscreenCoverGradientBlurSkin(),
    ]

    static let defaultSkinID: String = "kmgccc.cassette"

    static let defaultFullscreenSkinID: String = "kmgccc.cassette"

    static var fullscreenSkins: [any NowPlayingSkin] {
        skins.filter { $0.isFullscreenCompatible }
    }

    static var nowPlayingSkins: [any NowPlayingSkin] {
        skins.filter { $0.isNowPlayingCompatible }
    }

    static func skin(for id: String) -> any NowPlayingSkin {
        if let match = skins.first(where: { $0.id == id }) {
            return match
        }
        if let fallback = skins.first(where: { $0.id == defaultSkinID }) {
            return fallback
        }
        return skins.first ?? ClassicLEDSkin()
    }

    static func fullscreenSkin(for id: String) -> any NowPlayingSkin {
        fullscreenSkins.first { $0.id == id } ?? ClassicLEDSkin()
    }

    static var options: [SkinOption] {
        skins.map {
            SkinOption(
                id: $0.id,
                name: $0.name,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
    }

    static var fullscreenOptions: [SkinOption] {
        fullscreenSkins.map {
            SkinOption(
                id: $0.id,
                name: $0.name,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
    }

    static var nowPlayingOptions: [SkinOption] {
        nowPlayingSkins.map {
            SkinOption(
                id: $0.id,
                name: $0.name,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
    }
}
