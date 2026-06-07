//
//  TelemetryDefaultMigration2_1_1.swift
//  myPlayer2
//
//  TEMPORARY — 2.1.1 only.
//
//  The anonymous-usage consent default originally shipped as OFF, so almost no
//  users opted in and we collected effectively no usage data. Since the data is
//  anonymous, 2.1.1 performs a one-time correction that flips the stored consent
//  to ON.
//
//  This is a one-time migration, NOT a per-launch override:
//    - It runs at most once (guarded by a did-run flag).
//    - It only acts while the app version is exactly 2.1.1.
//    - After it runs, the consent toggle behaves normally — a user who turns it
//      back off keeps that choice and is never re-forced on.
//
//  REMOVAL: delete this file and its single call site in
//  AppSessionHost.setupDependencies() when shipping the next version.
//

import Foundation

enum TelemetryDefaultMigration2_1_1 {
    /// Shared with `TelemetryService` / the Settings toggle.
    private static let consentKey = "telemetry.anonymousUsageEnabled"
    /// Dedicated flag so the correction runs at most once, even if the user later opts out.
    private static let didRunKey = "telemetry.defaultOnMigration.2_1_1.didRun"
    private static let targetVersion = AppVersion(major: 2, minor: 1, patch: 2)

    /// Runs the one-time consent default correction if applicable. Must be called
    /// before `TelemetryService` reads consent at launch.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard AppVersion.current == targetVersion else { return }
        guard !defaults.bool(forKey: didRunKey) else { return }

        defaults.set(true, forKey: consentKey)
        defaults.set(true, forKey: didRunKey)
        Log.info(
            "[Telemetry] 2.1.1 one-time consent default correction applied (OFF→ON)",
            category: .telemetry
        )
    }
}
