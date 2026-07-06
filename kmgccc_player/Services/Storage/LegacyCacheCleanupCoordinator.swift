//
//  LegacyCacheCleanupCoordinator.swift
//  myPlayer2
//
//  Coordinates the Build 7 legacy cache cleanup prompt without blocking launch.
//

import Foundation

@MainActor
final class LegacyCacheCleanupCoordinator {
    static let shared = LegacyCacheCleanupCoordinator()

    private enum Keys {
        static let eligible = "kmgccc_player.legacyCacheCleanupBuild7Eligible"
        static let handled = "kmgccc_player.legacyCacheCleanupBuild7Handled"
        static let lastPromptDate = "kmgccc_player.legacyCacheCleanupBuild7LastPromptDate"
    }

    private let defaults: UserDefaults
    private var promptTask: Task<Void, Never>?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func captureBuild7UpgradeEligibilityBeforeLaunchRecord(versionGate: AppVersionGate = .shared) {
        guard AppBuild.current >= AppBuild(7) else { return }
        guard !defaults.bool(forKey: Keys.handled) else { return }
        guard defaults.bool(forKey: Keys.eligible) == false else { return }
        guard let lastRunBuild = versionGate.latestInstalledBuild else {
            return
        }
        guard lastRunBuild < AppBuild(7) else { return }
        defaults.set(true, forKey: Keys.eligible)
        Log.info(
            "[LegacyCacheCleanup] Build 7 cleanup eligible lastRunBuild=\(lastRunBuild)",
            category: .general
        )
    }

    func schedulePromptIfNeeded(presentPrompt: @MainActor @escaping () -> Void) {
        guard promptTask == nil else { return }
        promptTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            await self?.evaluateAndPresentIfNeeded(presentPrompt: presentPrompt)
        }
    }

    func remindLater() {
        defaults.set(Date(), forKey: Keys.lastPromptDate)
    }

    func markHandled() {
        defaults.set(true, forKey: Keys.handled)
        defaults.removeObject(forKey: Keys.eligible)
    }

    func clearLegacyCaches() async -> LegacyCacheCleanupResult {
        let result = await CacheManager.clearBuild7LegacyCaches()
        markHandled()
        Log.info(
            "[LegacyCacheCleanup] Build 7 cleanup complete removed=\(result.removedItemCount) failed=\(result.failedItemCount)",
            category: .general
        )
        return result
    }

    private func evaluateAndPresentIfNeeded(presentPrompt: @MainActor @escaping () -> Void) async {
        guard AppBuild.current >= AppBuild(7) else { return }
        guard defaults.bool(forKey: Keys.eligible) else { return }
        guard !defaults.bool(forKey: Keys.handled) else { return }
        guard shouldPromptNow else { return }

        let hasLegacyCaches = await CacheManager.hasBuild7LegacyCaches()
        guard hasLegacyCaches else {
            markHandled()
            return
        }

        presentPrompt()
    }

    private var shouldPromptNow: Bool {
        guard let lastPromptDate = defaults.object(forKey: Keys.lastPromptDate) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastPromptDate) >= 20 * 60 * 60
    }
}
