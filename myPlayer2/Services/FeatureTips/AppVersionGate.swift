//
//  AppVersionGate.swift
//  myPlayer2
//
//  kmgccc_player - Shared version and feature-tip gate.
//

import Foundation

final class AppVersionGate {
    static let shared = AppVersionGate()

    private enum Keys {
        static let previousInstalledVersion = "kmgccc_player.previousInstalledVersion"
        static let latestInstalledVersion = "kmgccc_player.latestInstalledVersion"
        static let lastSeenWhatsNewVersion = "kmgccc_player.lastSeenWhatsNewVersion"
        static let dismissedFeatureTipPrefix = "kmgccc_player.dismissedFeatureTip."
        static let featureTipDisplayCountPrefix = "kmgccc_player.featureTipDisplayCount."
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var currentAppVersion: AppVersion {
        AppVersion.current
    }

    var previousInstalledVersion: AppVersion? {
        get { version(forKey: Keys.previousInstalledVersion) }
        set { setVersion(newValue, forKey: Keys.previousInstalledVersion) }
    }

    var latestInstalledVersion: AppVersion? {
        get { version(forKey: Keys.latestInstalledVersion) }
        set { setVersion(newValue, forKey: Keys.latestInstalledVersion) }
    }

    var lastSeenWhatsNewVersion: AppVersion? {
        get { version(forKey: Keys.lastSeenWhatsNewVersion) }
        set { setVersion(newValue, forKey: Keys.lastSeenWhatsNewVersion) }
    }

    func recordCurrentAppLaunch(currentVersion: AppVersion = AppVersion.current) {
        let storedLatest = latestInstalledVersion

        if storedLatest == currentVersion {
            if previousInstalledVersion == nil,
               let legacyLastSeen = lastSeenWhatsNewVersion,
               legacyLastSeen < currentVersion
            {
                previousInstalledVersion = legacyLastSeen
            }
            return
        }

        previousInstalledVersion = storedLatest ?? previousInstalledVersion ?? lastSeenWhatsNewVersion
        latestInstalledVersion = currentVersion
    }

    func wasUpgradedFromVersionBelow(_ versionString: String) -> Bool {
        guard let version = AppVersion(from: versionString) else { return false }
        return wasUpgradedFromVersionBelow(version)
    }

    func wasUpgradedFromVersionBelow(_ version: AppVersion) -> Bool {
        guard let previousInstalledVersion else { return false }
        let latestVersion = latestInstalledVersion ?? currentAppVersion
        return previousInstalledVersion < version && latestVersion >= version
    }

    func shouldShowWhatsNew(targetVersion: AppVersion) -> Bool {
        guard let lastSeen = lastSeenWhatsNewVersion else { return true }
        return lastSeen < targetVersion
    }

    func markWhatsNewSeen(targetVersion: AppVersion) {
        lastSeenWhatsNewVersion = targetVersion
    }

    func isFeatureTipDismissed(featureKey: String) -> Bool {
        defaults.bool(forKey: dismissedFeatureTipKey(featureKey))
    }

    func markFeatureTipDismissed(featureKey: String) {
        defaults.set(true, forKey: dismissedFeatureTipKey(featureKey))
    }

    func featureTipDisplayCount(featureKey: String) -> Int {
        defaults.integer(forKey: featureTipDisplayCountKey(featureKey))
    }

    func recordFeatureTipDisplayed(featureKey: String) {
        let key = featureTipDisplayCountKey(featureKey)
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    func shouldShowFeatureTip(featureKey: String, introducedVersion: AppVersion) -> Bool {
        shouldShowFeatureTip(featureKey: featureKey, introducedVersion: introducedVersion, maxDisplayCount: 4)
    }

    func shouldShowFeatureTip(
        featureKey: String,
        introducedVersion: AppVersion,
        maxDisplayCount: Int
    ) -> Bool {
        !isFeatureTipDismissed(featureKey: featureKey)
            && featureTipDisplayCount(featureKey: featureKey) < maxDisplayCount
            && wasUpgradedFromVersionBelow(introducedVersion)
    }

    func shouldShowFeatureTip(featureKey: String, introducedVersion versionString: String) -> Bool {
        guard let version = AppVersion(from: versionString) else { return false }
        return shouldShowFeatureTip(featureKey: featureKey, introducedVersion: version)
    }

    func resetStoredState() {
        defaults.removeObject(forKey: Keys.previousInstalledVersion)
        defaults.removeObject(forKey: Keys.latestInstalledVersion)
        defaults.removeObject(forKey: Keys.lastSeenWhatsNewVersion)

        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(Keys.dismissedFeatureTipPrefix)
                || key.hasPrefix(Keys.featureTipDisplayCountPrefix)
        {
            defaults.removeObject(forKey: key)
        }
    }

    private func dismissedFeatureTipKey(_ featureKey: String) -> String {
        Keys.dismissedFeatureTipPrefix + featureKey
    }

    private func featureTipDisplayCountKey(_ featureKey: String) -> String {
        Keys.featureTipDisplayCountPrefix + featureKey
    }

    private func version(forKey key: String) -> AppVersion? {
        guard let string = defaults.string(forKey: key) else { return nil }
        return AppVersion(from: string)
    }

    private func setVersion(_ version: AppVersion?, forKey key: String) {
        if let version {
            defaults.set(version.stringValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
