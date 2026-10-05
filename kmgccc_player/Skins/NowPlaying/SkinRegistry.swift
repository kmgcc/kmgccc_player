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

    static let catalog: SkinCatalog = {
        let renderers: [any NowPlayingSkin] = [
            ClassicLEDSkin(), AppleStyleSkin(), RotatingCoverSkin(),
            KmgcccCassetteSkin(), FullscreenCoverGradientBlurSkin(),
        ]
        let catalog = SkinCatalog(skins: [])
        NativeSkinComponents.register(in: catalog.components)
        for renderer in renderers {
            catalog.registerBundled(renderer)
        }
        catalog.packages.loadInstalled()
        #if DEBUG
        if CommandLine.arguments.contains("--skin-development-example") {
            catalog.register(MinimalSkinExample())
            SkinDevelopmentScenes.packages.forEach { catalog.register($0) }
        }
        #endif
        return catalog
    }()

    static var skins: [any NowPlayingSkin] { catalog.skins }

    static func registeredDescriptor(for id: String) -> SkinDescriptor? {
        catalog.registeredSkin(for: id)?.descriptor
    }

    static func descriptor(for id: String) -> SkinDescriptor {
        skin(for: id).descriptor
    }

    static func releaseCachedResources() async {
        for skin in skins {
            await skin.releaseCachedResources()
        }
    }

    static let defaultSkinID: String = "kmgccc.cassette"

    static let defaultFullscreenSkinID: String = "kmgccc.cassette"

    static var fullscreenSkins: [any NowPlayingSkin] {
        catalog.skins(for: .fullscreen)
    }

    static var nowPlayingSkins: [any NowPlayingSkin] {
        catalog.skins(for: .window)
    }

    static func skin(for id: String) -> any NowPlayingSkin {
        let resolvedID = SkinRoutePolicy.resolvedID(
            requestedID: id,
            availableIDs: skins.map(\.id),
            defaultID: defaultSkinID,
            fallbackID: ClassicLEDSkin.id
        )
        return skins.first(where: { $0.id == resolvedID }) ?? ClassicLEDSkin()
    }

    static func fullscreenSkin(for id: String) -> any NowPlayingSkin {
        let fallbackID = ClassicLEDSkin.id
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
        fullscreenSkins.enumerated().sorted { lhs, rhs in
            let leftOrder = lhs.element.descriptor.fullscreenOrder
            let rightOrder = rhs.element.descriptor.fullscreenOrder
            return leftOrder == rightOrder ? lhs.offset < rhs.offset : leftOrder < rightOrder
        }.map {
            SkinOption(
                id: $0.element.id,
                name: $0.element.name,
                detail: $0.element.detail,
                systemImage: $0.element.systemImage
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
