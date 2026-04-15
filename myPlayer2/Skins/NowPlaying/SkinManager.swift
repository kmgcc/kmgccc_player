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

    var selectedNormalSkinID: String {
        get { resolveNormalSkinID(AppSettings.shared.normalSkinID) }
        set { AppSettings.shared.normalSkinID = resolveNormalSkinID(newValue) }
    }

    var selectedFullscreenSkinID: String {
        get { resolveFullscreenSkinID(AppSettings.shared.fullscreen.skinID) }
        set { AppSettings.shared.fullscreen.setSkinID(resolveFullscreenSkinID(newValue)) }
    }

    var selectedNormalSkin: any NormalSkin {
        SkinRegistry.normalSkin(for: selectedNormalSkinID)
    }

    var selectedFullscreenSkin: any FullscreenSkin {
        SkinRegistry.fullscreenSkin(for: selectedFullscreenSkinID)
    }

    func normalSkin(for id: String) -> any NormalSkin {
        SkinRegistry.normalSkin(for: resolveNormalSkinID(id))
    }

    func fullscreenSkin(for id: String) -> any FullscreenSkin {
        SkinRegistry.fullscreenSkin(for: resolveFullscreenSkinID(id))
    }

    private func resolveNormalSkinID(_ id: String) -> String {
        if SkinRegistry.normalSkinThemes.contains(where: { $0.id == id }) {
            return id
        }
        return SkinRegistry.defaultSkinID
    }

    private func resolveFullscreenSkinID(_ id: String) -> String {
        if SkinRegistry.fullscreenSkinThemes.contains(where: { $0.id == id }) {
            return id
        }
        return SkinRegistry.defaultFullscreenSkinID
    }
}
