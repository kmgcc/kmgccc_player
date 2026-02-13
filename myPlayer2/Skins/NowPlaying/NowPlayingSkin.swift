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

    func makeBackground(context: SkinContext) -> AnyView
    func makeArtwork(context: SkinContext) -> AnyView
    func makeOverlay(context: SkinContext) -> AnyView?
    var settingsView: AnyView? { get }
}

extension NowPlayingSkin {
    func makeOverlay(context: SkinContext) -> AnyView? {
        nil
    }

    var settingsView: AnyView? {
        nil
    }
}
