//
//  SkinManager.swift
//  myPlayer2
//
//  kmgccc_player - Now Playing Skin Manager
//

import SwiftUI

@Observable
@MainActor
final class SkinManager {

    var selectedSkinID: String {
        get { resolveSkinID(AppSettings.shared.selectedNowPlayingSkinID) }
        set { AppSettings.shared.selectedNowPlayingSkinID = resolveSkinID(newValue) }
    }

    var selectedSkin: any NowPlayingSkin {
        SkinRegistry.skin(for: selectedSkinID)
    }

    func skin(for id: String) -> any NowPlayingSkin {
        SkinRegistry.skin(for: resolveSkinID(id))
    }

    private func resolveSkinID(_ id: String) -> String {
        if SkinRegistry.skins.contains(where: { $0.id == id }) {
            return id
        }
        return SkinRegistry.defaultSkinID
    }
}
