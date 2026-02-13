//
//  SkinRegistry.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Skin Registry
//

import Foundation

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
    ]

    static let defaultSkinID: String = ClassicLEDSkin.id

    static func skin(for id: String) -> any NowPlayingSkin {
        if let match = skins.first(where: { $0.id == id }) {
            return match
        }
        return skins.first ?? ClassicLEDSkin()
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
}
