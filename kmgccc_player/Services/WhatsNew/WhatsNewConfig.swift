//
//  WhatsNewConfig.swift
//  myPlayer2
//
//  kmgccc_player - WhatsNew presentation configuration and state management
//

import Foundation
import WhatsNewKit

enum WhatsNewConfig {

    static let targetBuild = AppBuild(16)
    static let whatsNewVersion = WhatsNew.Version(major: 2, minor: 4, patch: 1)
    
    static var lastSeenBuild: AppBuild? {
        get { AppVersionGate.shared.lastSeenWhatsNewBuild }
        set { AppVersionGate.shared.lastSeenWhatsNewBuild = newValue }
    }

    static var shouldShowWelcome: Bool {
        AppVersionGate.shared.shouldShowWelcome
    }
    
    static func shouldShowWhatsNew() -> Bool {
        AppVersionGate.shared.shouldShowWhatsNew(targetBuild: targetBuild)
    }

    static func shouldShowAnnouncement() -> Bool {
        shouldShowWelcome || shouldShowWhatsNew()
    }
    
    static func markAsSeen() {
        if shouldShowWelcome {
            AppVersionGate.shared.markWelcomeSeen(targetBuild: targetBuild)
        } else {
            AppVersionGate.shared.markWhatsNewSeen(targetBuild: targetBuild)
        }
    }
}
