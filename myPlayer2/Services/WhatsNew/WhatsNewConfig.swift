//
//  WhatsNewConfig.swift
//  myPlayer2
//
//  kmgccc_player - WhatsNew presentation configuration and state management
//

import Foundation
import WhatsNewKit

enum WhatsNewConfig {

    static let targetVersion = AppVersion(major: 1, minor: 3, patch: 1)
    static let whatsNewVersion = WhatsNew.Version(major: 1, minor: 3, patch: 1)
    
    static var lastSeenVersion: AppVersion? {
        get { AppVersionGate.shared.lastSeenWhatsNewVersion }
        set { AppVersionGate.shared.lastSeenWhatsNewVersion = newValue }
    }
    
    static func shouldShowWhatsNew() -> Bool {
        AppVersionGate.shared.shouldShowWhatsNew(targetVersion: targetVersion)
    }
    
    static func markAsSeen() {
        AppVersionGate.shared.markWhatsNewSeen(targetVersion: targetVersion)
    }
}
