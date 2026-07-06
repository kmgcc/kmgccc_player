//
//  AppVersionGate.swift
//  myPlayer2
//
//  kmgccc_player - Shared build and feature-tip gate.
//

import Foundation

enum FeatureTipCatalog {
    static let enabledFeatureKeys: Set<String> = [
        "fullscreen.playbackModeRetap",
        "playbackSource.externalAppPlayback",
        "playlist.shiftRangeSelection"
    ]

    static func isEnabled(featureKey: String) -> Bool {
        enabledFeatureKeys.contains(featureKey)
    }
}

final class AppVersionGate {
    static let shared = AppVersionGate()

    private enum Keys {
        static let previousInstalledBuild = "kmgccc_player.previousInstalledBuild"
        static let latestInstalledBuild = "kmgccc_player.latestInstalledBuild"
        static let lastSeenWhatsNewBuild = "kmgccc_player.lastSeenWhatsNewBuild"
        static let legacyPreviousInstalledVersion = "kmgccc_player.previousInstalledVersion"
        static let legacyLatestInstalledVersion = "kmgccc_player.latestInstalledVersion"
        static let legacyLastSeenWhatsNewVersion = "kmgccc_player.lastSeenWhatsNewVersion"
        static let dismissedFeatureTipPrefix = "kmgccc_player.dismissedFeatureTip."
        static let featureTipDisplayCountPrefix = "kmgccc_player.featureTipDisplayCount."
    }

    private static let legacyVersionBuilds: [String: AppBuild] = [
        "1.2.1": .legacyBaseline,
        "1.2.2": .legacyBaseline,
        "1.3.1": .legacyBaseline,
        "1.4.1": .legacyBaseline,
        "2.0.0": AppBuild(1),
        "2.1.0": AppBuild(3),
        "2.1.1": AppBuild(4),
        "2.1.2": AppBuild(5),
        "2.1.3": AppBuild(6)
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var currentAppBuild: AppBuild {
        AppBuild.current
    }

    var previousInstalledBuild: AppBuild? {
        get { build(forKey: Keys.previousInstalledBuild) ?? legacyBuild(forKey: Keys.legacyPreviousInstalledVersion) }
        set { setBuild(newValue, forKey: Keys.previousInstalledBuild) }
    }

    var latestInstalledBuild: AppBuild? {
        get { build(forKey: Keys.latestInstalledBuild) ?? legacyBuild(forKey: Keys.legacyLatestInstalledVersion) }
        set { setBuild(newValue, forKey: Keys.latestInstalledBuild) }
    }

    var lastSeenWhatsNewBuild: AppBuild? {
        get { build(forKey: Keys.lastSeenWhatsNewBuild) ?? legacyBuild(forKey: Keys.legacyLastSeenWhatsNewVersion) }
        set { setBuild(newValue, forKey: Keys.lastSeenWhatsNewBuild) }
    }

    func recordCurrentAppLaunch(currentBuild: AppBuild = AppBuild.current) {
        let storedLatest = latestInstalledBuild

        if storedLatest == currentBuild {
            // Legacy migration: users upgrading from versions that predate build
            // tracking may have latestInstalledBuild set but no previousInstalledBuild.
            // Treat them as coming from a very old version so Feature Tips can display.
            if previousInstalledBuild == nil {
                previousInstalledBuild = .legacyBaseline
            }
            return
        }

        let previous = storedLatest ?? previousInstalledBuild ?? lastSeenWhatsNewBuild ?? .legacyBaseline
        previousInstalledBuild = previous
        latestInstalledBuild = currentBuild

        // If upgrading from a build below 7, reset the shiftRangeSelection key's state
        // because we are changing this feature tip from "Shift select" to "Drag to sort"
        // and want all upgrading users to see it up to 2 times.
        if previous < AppBuild(7) && currentBuild >= AppBuild(7) {
            defaults.removeObject(forKey: dismissedFeatureTipKey("playlist.shiftRangeSelection"))
            defaults.removeObject(forKey: featureTipDisplayCountKey("playlist.shiftRangeSelection"))
            Log.debug("[AppVersionGate] Reset playlist.shiftRangeSelection state for upgrade from Build \(previous.rawValue) to Build \(currentBuild.rawValue)", category: .ui)
        }
    }

    func wasUpgradedFromBuildBelow(_ buildNumber: Int) -> Bool {
        wasUpgradedFromBuildBelow(AppBuild(buildNumber))
    }

    func wasUpgradedFromBuildBelow(_ build: AppBuild) -> Bool {
        guard let previous = previousInstalledBuild else {
            // Missing previousInstalledBuild means the migration state was never
            // recorded. If latestInstalledBuild is present the user has launched
            // the app before — treat as upgrade from a very old build so Feature
            // Tips can display.
            return latestInstalledBuild != nil
        }
        let latest = latestInstalledBuild ?? currentAppBuild
        return previous < build && latest >= build
    }

    func shouldShowWhatsNew(targetBuild: AppBuild) -> Bool {
        guard let lastSeen = lastSeenWhatsNewBuild else { return true }
        return lastSeen < targetBuild
    }

    func markWhatsNewSeen(targetBuild: AppBuild) {
        lastSeenWhatsNewBuild = targetBuild
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

    func shouldShowFeatureTip(featureKey: String, introducedBuild: AppBuild) -> Bool {
        shouldShowFeatureTip(featureKey: featureKey, introducedBuild: introducedBuild, maxDisplayCount: 4)
    }

    func shouldShowFeatureTip(
        featureKey: String,
        introducedBuild: AppBuild,
        maxDisplayCount: Int
    ) -> Bool {
        FeatureTipCatalog.isEnabled(featureKey: featureKey)
            && !isFeatureTipDismissed(featureKey: featureKey)
            && featureTipDisplayCount(featureKey: featureKey) < maxDisplayCount
            && wasUpgradedFromBuildBelow(introducedBuild)
    }

    func resetStoredState() {
        defaults.removeObject(forKey: Keys.previousInstalledBuild)
        defaults.removeObject(forKey: Keys.latestInstalledBuild)
        defaults.removeObject(forKey: Keys.lastSeenWhatsNewBuild)
        defaults.removeObject(forKey: Keys.legacyPreviousInstalledVersion)
        defaults.removeObject(forKey: Keys.legacyLatestInstalledVersion)
        defaults.removeObject(forKey: Keys.legacyLastSeenWhatsNewVersion)

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

    private func build(forKey key: String) -> AppBuild? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return AppBuild(defaults.integer(forKey: key))
    }

    private func setBuild(_ build: AppBuild?, forKey key: String) {
        if let build {
            defaults.set(build.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func legacyBuild(forKey key: String) -> AppBuild? {
        guard let version = version(forKey: key) else { return nil }
        return Self.legacyVersionBuilds[version.stringValue] ?? .legacyBaseline
    }

    private func version(forKey key: String) -> AppVersion? {
        guard let string = defaults.string(forKey: key) else { return nil }
        return AppVersion(from: string)
    }
}
