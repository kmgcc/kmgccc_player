//
//  NowPlayingSkin.swift
//  myPlayer2
//
//  TrueMusic - Now Playing Skins
//  Shared skin identifiers for the Now Playing screen.
//

import Foundation

enum NowPlayingSkin: String, CaseIterable, Identifiable {
    case coverLed
    case rotatingCover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coverLed: return "Cover + LED"
        case .rotatingCover: return "Rotating Cover"
        }
    }

    var systemImage: String {
        switch self {
        case .coverLed: return "rectangle.stack"
        case .rotatingCover: return "arrow.2.circlepath"
        }
    }
}

