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
    let catalog: SkinCatalog

    init(catalog: SkinCatalog = SkinRegistry.catalog) {
        self.catalog = catalog
    }

    var selectedSkinID: String {
        get { resolveSkinID(AppSettings.shared.selectedNowPlayingSkinID) }
        set { AppSettings.shared.selectedNowPlayingSkinID = resolveSkinID(newValue) }
    }

    var selectedSkin: any NowPlayingSkin {
        skin(for: selectedSkinID)
    }

    func skin(for id: String) -> any NowPlayingSkin {
        catalog.registeredSkin(for: resolveSkinID(id))
            ?? SkinRegistry.skin(for: SkinRegistry.defaultSkinID)
    }

    func removePackage(_ skinID: String, settings: AppSettings) throws {
        let windowSelected = settings.selectedNowPlayingSkinID == skinID
        let fullscreenSelected = settings.fullscreen.skinID == skinID
        try catalog.packages.removePackage(skinID)
        if windowSelected { settings.selectedNowPlayingSkinID = SkinRegistry.defaultSkinID }
        if fullscreenSelected { settings.fullscreen.setSkinID(SkinRegistry.defaultFullscreenSkinID) }
    }

    private func resolveSkinID(_ id: String) -> String {
        if catalog.skins(for: .window).contains(where: { $0.id == id }) {
            return id
        }
        return SkinRegistry.defaultSkinID
    }
}
