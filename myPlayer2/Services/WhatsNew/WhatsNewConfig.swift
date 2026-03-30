//
//  WhatsNewConfig.swift
//  myPlayer2
//
//  kmgccc_player - WhatsNew presentation configuration and state management
//

import Foundation

enum WhatsNewConfig {
    
    static let targetVersion: AppVersion = AppVersion(major: 1, minor: 2, patch: 1)
    
    static let userDefaultsKey = "kmgccc_player.lastSeenWhatsNewVersion"
    
    static var lastSeenVersion: AppVersion? {
        get {
            guard let string = UserDefaults.standard.string(forKey: userDefaultsKey) else { return nil }
            return AppVersion(from: string)
        }
        set {
            if let version = newValue {
                UserDefaults.standard.set(version.stringValue, forKey: userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            }
        }
    }
    
    static func shouldShowWhatsNew() -> Bool {
        guard let lastSeen = lastSeenVersion else { return true }
        return lastSeen < targetVersion
    }
    
    static func markAsSeen() {
        lastSeenVersion = targetVersion
    }
}