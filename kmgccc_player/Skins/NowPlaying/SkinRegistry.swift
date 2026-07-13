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
        AppleStyleSkin(),
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
        let resolvedID = SkinRoutePolicy.resolvedID(
            requestedID: id,
            availableIDs: skins.map(\.id),
            defaultID: defaultSkinID,
            fallbackID: ClassicLEDSkin().id
        )
        return skins.first(where: { $0.id == resolvedID }) ?? ClassicLEDSkin()
    }

    static func fullscreenSkin(for id: String) -> any NowPlayingSkin {
        let fallbackID = ClassicLEDSkin().id
        let resolvedID = SkinRoutePolicy.resolvedID(
            requestedID: id,
            availableIDs: fullscreenSkins.map(\.id),
            defaultID: fallbackID,
            fallbackID: fallbackID
        )
        return fullscreenSkins.first { $0.id == resolvedID } ?? ClassicLEDSkin()
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
        fullscreenSkins.sorted { lhs, rhs in
            fullscreenSortRank(for: lhs.id) < fullscreenSortRank(for: rhs.id)
        }.map {
            SkinOption(
                id: $0.id,
                name: $0.name,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
    }

    private static func fullscreenSortRank(for id: String) -> Int {
        SkinRoutePolicy.sortRank(
            for: id,
            prioritizedID: "fullscreen.coverGradientBlur",
            orderedIDs: skins.map(\.id)
        )
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
