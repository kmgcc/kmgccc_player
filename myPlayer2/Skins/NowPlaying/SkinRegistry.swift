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

@MainActor
enum SkinRegistry {

    static let themes: [any SkinTheme] = [
        ClassicLEDTheme(),
        RotatingCoverTheme(),
        KmgcccCassetteTheme(),
        CoverGradientBlurTheme(),
    ]

    static let defaultSkinID: String = "kmgccc.cassette"

    static let defaultFullscreenSkinID: String = "kmgccc.cassette"

    static var normalSkinThemes: [any SkinTheme] {
        themes.filter { $0.normal != nil }
    }

    static var fullscreenSkinThemes: [any SkinTheme] {
        themes.filter { $0.fullscreen != nil }
    }

    static func normalSkin(for id: String) -> any NormalSkin {
        if let match = themes.first(where: { $0.id == id && $0.normal != nil })?.normal {
            return match
        }
        if let fallback = themes.first(where: { $0.id == defaultSkinID })?.normal {
            return fallback
        }
        return themes.first(where: { $0.normal != nil })!.normal!
    }

    static func fullscreenSkin(for id: String) -> any FullscreenSkin {
        if let match = themes.first(where: { $0.id == id && $0.fullscreen != nil })?.fullscreen {
            return match
        }
        if let fallback = themes.first(where: { $0.id == defaultFullscreenSkinID })?.fullscreen {
            return fallback
        }
        return themes.first(where: { $0.fullscreen != nil })!.fullscreen!
    }

    static var options: [SkinOption] {
        themes.map {
            SkinOption(
                id: $0.id,
                name: $0.name,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
    }

    static var normalOptions: [SkinOption] {
        normalSkinThemes.map {
            SkinOption(
                id: $0.id,
                name: $0.name,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
    }

    static var fullscreenOptions: [SkinOption] {
        fullscreenSkinThemes.map {
            SkinOption(
                id: $0.id,
                name: $0.name,
                detail: $0.detail,
                systemImage: $0.systemImage
            )
        }
    }
}
