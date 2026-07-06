//
//  WhatsNewConfig.swift
//  myPlayer2
//
//  kmgccc_player - WhatsNew presentation configuration and state management
//

import Foundation
import WhatsNewKit

enum WhatsNewConfig {

    static let targetBuild = AppBuild(1)
    static let whatsNewVersion = WhatsNew.Version(major: 2, minor: 0, patch: 0)
    
    static var lastSeenBuild: AppBuild? {
        get { AppVersionGate.shared.lastSeenWhatsNewBuild }
        set { AppVersionGate.shared.lastSeenWhatsNewBuild = newValue }
    }
    
    static func shouldShowWhatsNew() -> Bool {
        AppVersionGate.shared.shouldShowWhatsNew(targetBuild: targetBuild)
    }
    
    static func markAsSeen() {
        AppVersionGate.shared.markWhatsNewSeen(targetBuild: targetBuild)
    }
}
