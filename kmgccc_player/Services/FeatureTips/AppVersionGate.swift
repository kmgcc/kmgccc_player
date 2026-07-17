//
//  AppVersionGate.swift
//  myPlayer2
//
//  kmgccc_player - Shared build and feature-tip gate.
//

import Foundation

enum FeatureTipCatalog {
    enum PlaybackModeRetap {
        static let key = "fullscreen.playbackModeRetap"
        static let introducedBuild = AppBuild(8)
        static let maxDisplayCount = 2
        static let playbackStartDelay: TimeInterval = 3
        static let behaviorRevision = 2
    }

    static let enabledFeatureKeys: Set<String> = [
        PlaybackModeRetap.key,
        "playlist.shiftRangeSelection",
        "dataSharing.automaticCrashReports"
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
        static let featureTipReadyForNextLaunchPrefix = "kmgccc_player.featureTipReadyForNextLaunch."
        static let featureTipBehaviorRevisionPrefix = "kmgccc_player.featureTipBehaviorRevision."
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
    private var claimedFeatureTipsThisLaunch = Set<String>()

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
        migratePlaybackModeRetapTipIfNeeded(currentBuild: currentBuild)

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

    /// Claims a display slot for a tip that must be shown at most once per app
    /// launch. The playback-order tip uses the second slot only after the
    /// first presentation was closed and a new app launch has begun.
    func claimFeatureTipDisplay(
        featureKey: String,
        introducedBuild: AppBuild,
        maxDisplayCount: Int,
        requiresDismissalBeforeNextLaunch: Bool = false,
        allowsCurrentBehaviorRevision: Bool = false
    ) -> Bool {
        guard !claimedFeatureTipsThisLaunch.contains(featureKey) else { return false }
        guard shouldShowFeatureTip(
            featureKey: featureKey,
            introducedBuild: introducedBuild,
            maxDisplayCount: maxDisplayCount,
            allowsCurrentBehaviorRevision: allowsCurrentBehaviorRevision
        ) else { return false }

        let count = featureTipDisplayCount(featureKey: featureKey)
        if requiresDismissalBeforeNextLaunch, count > 0 {
            guard defaults.bool(forKey: featureTipReadyForNextLaunchKey(featureKey)) else {
                return false
            }
        }

        recordFeatureTipDisplayed(featureKey: featureKey)
        claimedFeatureTipsThisLaunch.insert(featureKey)
        defaults.removeObject(forKey: featureTipReadyForNextLaunchKey(featureKey))
        return true
    }

    func claimPlaybackModeRetapFeatureTipDisplay() -> Bool {
        claimFeatureTipDisplay(
            featureKey: FeatureTipCatalog.PlaybackModeRetap.key,
            introducedBuild: FeatureTipCatalog.PlaybackModeRetap.introducedBuild,
            maxDisplayCount: FeatureTipCatalog.PlaybackModeRetap.maxDisplayCount,
            requiresDismissalBeforeNextLaunch: true,
            allowsCurrentBehaviorRevision: true
        )
    }

    /// Temporary close semantics for the playback-order tip. The next slot
    /// is intentionally unlocked only for the next app launch.
    func markPlaybackModeRetapFeatureTipDismissed() {
        let featureKey = FeatureTipCatalog.PlaybackModeRetap.key
        guard featureTipDisplayCount(featureKey: featureKey) > 0 else { return }
        defaults.set(true, forKey: featureTipReadyForNextLaunchKey(featureKey))
    }

    func shouldShowFeatureTip(featureKey: String, introducedBuild: AppBuild) -> Bool {
        shouldShowFeatureTip(
            featureKey: featureKey,
            introducedBuild: introducedBuild,
            maxDisplayCount: 4
        )
    }

    func shouldShowFeatureTip(
        featureKey: String,
        introducedBuild: AppBuild,
        maxDisplayCount: Int,
        allowsCurrentBehaviorRevision: Bool = false
    ) -> Bool {
        FeatureTipCatalog.isEnabled(featureKey: featureKey)
            && !isFeatureTipDismissed(featureKey: featureKey)
            && featureTipDisplayCount(featureKey: featureKey) < maxDisplayCount
            && (
                wasUpgradedFromBuildBelow(introducedBuild)
                    || (allowsCurrentBehaviorRevision && hasCurrentBehaviorRevision(featureKey: featureKey))
            )
    }

    func resetStoredState() {
        defaults.removeObject(forKey: Keys.previousInstalledBuild)
        defaults.removeObject(forKey: Keys.latestInstalledBuild)
        defaults.removeObject(forKey: Keys.lastSeenWhatsNewBuild)
        defaults.removeObject(forKey: Keys.legacyPreviousInstalledVersion)
        defaults.removeObject(forKey: Keys.legacyLatestInstalledVersion)
        defaults.removeObject(forKey: Keys.legacyLastSeenWhatsNewVersion)
        claimedFeatureTipsThisLaunch.removeAll()

        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(Keys.dismissedFeatureTipPrefix)
                || key.hasPrefix(Keys.featureTipDisplayCountPrefix)
                || key.hasPrefix(Keys.featureTipReadyForNextLaunchPrefix)
                || key.hasPrefix(Keys.featureTipBehaviorRevisionPrefix)
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

    private func featureTipReadyForNextLaunchKey(_ featureKey: String) -> String {
        Keys.featureTipReadyForNextLaunchPrefix + featureKey
    }

    private func featureTipBehaviorRevisionKey(_ featureKey: String) -> String {
        Keys.featureTipBehaviorRevisionPrefix + featureKey
    }

    private func hasCurrentBehaviorRevision(featureKey: String) -> Bool {
        guard featureKey == FeatureTipCatalog.PlaybackModeRetap.key else { return false }
        return defaults.integer(forKey: featureTipBehaviorRevisionKey(featureKey))
            >= FeatureTipCatalog.PlaybackModeRetap.behaviorRevision
    }

    private func migratePlaybackModeRetapTipIfNeeded(currentBuild: AppBuild) {
        let featureKey = FeatureTipCatalog.PlaybackModeRetap.key
        let introducedBuild = FeatureTipCatalog.PlaybackModeRetap.introducedBuild
        let behaviorRevision = FeatureTipCatalog.PlaybackModeRetap.behaviorRevision
        guard currentBuild >= introducedBuild,
              defaults.integer(forKey: featureTipBehaviorRevisionKey(featureKey)) < behaviorRevision
        else { return }

        defaults.removeObject(forKey: dismissedFeatureTipKey(featureKey))
        defaults.removeObject(forKey: featureTipDisplayCountKey(featureKey))
        defaults.removeObject(forKey: featureTipReadyForNextLaunchKey(featureKey))
        defaults.set(behaviorRevision, forKey: featureTipBehaviorRevisionKey(featureKey))
        Log.debug(
            "[AppVersionGate] Reset \(featureKey) state for behavior revision \(behaviorRevision) at Build \(currentBuild.rawValue)",
            category: .ui
        )
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
