//
//  UpdatePolicy.swift
//  myPlayer2
//

import Foundation

enum UpdateReleaseChannel: String, Equatable {
    case production
    case test
}

enum UpdateEnvironmentError: Error, Equatable {
    case unsupportedChannel(String)
    case missingValue(String)
    case invalidURL(String)
    case invalidTestBundleIdentifier
    case invalidTestDisplayName
    case productionKeyReuse
}

struct UpdateEnvironment: Equatable {
    static let releaseChannelKey = "KMGUpdateReleaseChannel"
    static let primaryFeedURLKey = "KMGUpdatePrimaryFeedURL"
    static let fallbackFeedURLKey = "KMGUpdateFallbackFeedURL"
    static let testPrimaryFeedURLKey = "KMGTestUpdatePrimaryFeedURL"
    static let testFallbackFeedURLKey = "KMGTestUpdateFallbackFeedURL"
    static let testPublicKeyKey = "KMGTestUpdatePublicEDKey"
    static let productionPublicKeyKey = "KMGProductionUpdatePublicEDKey"
    static let publicKeyKey = "SUPublicEDKey"
    static let bundleIdentifierKey = "CFBundleIdentifier"
    static let displayNameKey = "CFBundleDisplayName"

    let releaseChannel: UpdateReleaseChannel
    let primaryFeedURL: URL
    let fallbackFeedURL: URL
    let publicKey: String

    var allowedSparkleChannels: Set<String> {
        releaseChannel == .test ? ["test"] : []
    }

    static func resolve(info: [String: Any]) throws -> UpdateEnvironment {
        let rawChannel = trimmedString(info[releaseChannelKey])
        let releaseChannel: UpdateReleaseChannel
        if let rawChannel, !rawChannel.isEmpty {
            guard let parsed = UpdateReleaseChannel(rawValue: rawChannel.lowercased()) else {
                throw UpdateEnvironmentError.unsupportedChannel(rawChannel)
            }
            releaseChannel = parsed
        } else {
            releaseChannel = .production
        }

        let primaryKey = releaseChannel == .test
            ? testPrimaryFeedURLKey
            : primaryFeedURLKey
        let fallbackKey = releaseChannel == .test
            ? testFallbackFeedURLKey
            : fallbackFeedURLKey
        let primaryFeedURL = try requiredHTTPSURL(primaryKey, info: info)
        let fallbackFeedURL = try requiredHTTPSURL(fallbackKey, info: info)
        guard primaryFeedURL != fallbackFeedURL else {
            throw UpdateEnvironmentError.invalidURL(fallbackKey)
        }

        let publicKey = try requiredString(
            releaseChannel == .test ? testPublicKeyKey : publicKeyKey,
            info: info
        )
        if releaseChannel == .test {
            guard try requiredHTTPSURL(primaryFeedURLKey, info: info) == primaryFeedURL,
                  try requiredHTTPSURL(fallbackFeedURLKey, info: info) == fallbackFeedURL,
                  try requiredString(publicKeyKey, info: info) == publicKey else {
                throw UpdateEnvironmentError.missingValue(testPublicKeyKey)
            }
            guard primaryFeedURL.path == "/api/v1/updates/test/appcast.xml",
                  fallbackFeedURL.path.contains("/test/") else {
                throw UpdateEnvironmentError.invalidURL(fallbackKey)
            }
            guard try requiredString(bundleIdentifierKey, info: info).hasSuffix(".test") else {
                throw UpdateEnvironmentError.invalidTestBundleIdentifier
            }
            guard try requiredString(displayNameKey, info: info).hasSuffix(" Test") else {
                throw UpdateEnvironmentError.invalidTestDisplayName
            }
            guard try requiredString(productionPublicKeyKey, info: info) != publicKey else {
                throw UpdateEnvironmentError.productionKeyReuse
            }
        }

        return UpdateEnvironment(
            releaseChannel: releaseChannel,
            primaryFeedURL: primaryFeedURL,
            fallbackFeedURL: fallbackFeedURL,
            publicKey: publicKey
        )
    }

    private static func requiredHTTPSURL(
        _ key: String,
        info: [String: Any]
    ) throws -> URL {
        let value = try requiredString(key, info: info)
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw UpdateEnvironmentError.invalidURL(key)
        }
        return url
    }

    private static func requiredString(
        _ key: String,
        info: [String: Any]
    ) throws -> String {
        guard let value = trimmedString(info[key]), !value.isEmpty,
              !value.contains("$(") else {
            throw UpdateEnvironmentError.missingValue(key)
        }
        return value
    }

    private static func trimmedString(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum UpdateFallbackPolicy {
    static func shouldUseFallback(for error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code != NSURLErrorCancelled
                && nsError.code != NSURLErrorUserAuthenticationRequired
                && nsError.code != NSURLErrorUserCancelledAuthentication
        }

        guard nsError.domain == "SUSparkleErrorDomain" else { return false }
        return [1000, 1002, 1004, 2001].contains(nsError.code)
    }
}

enum UpdatePreferences {
    static let automaticUpdatesEnabledKey = "automaticUpdatesEnabled"
    static let migrationCompletedKey = "automaticUpdatesPreferenceMigrated"
    static let legacyLaunchCheckKey = "checkForUpdatesOnLaunch"
    static let suppressedBuildKey = "updateSuppressedBuild"
    static let readyMetadataKey = "updateReadyMetadata"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationCompletedKey) else { return }

        let automaticUpdatesEnabled: Bool
        if defaults.object(forKey: legacyLaunchCheckKey) != nil {
            automaticUpdatesEnabled = defaults.bool(forKey: legacyLaunchCheckKey)
        } else {
            automaticUpdatesEnabled = true
        }

        defaults.set(automaticUpdatesEnabled, forKey: automaticUpdatesEnabledKey)
        defaults.set(true, forKey: migrationCompletedKey)
    }

    static func automaticUpdatesEnabled(defaults: UserDefaults = .standard) -> Bool {
        migrateIfNeeded(defaults: defaults)
        return defaults.bool(forKey: automaticUpdatesEnabledKey)
    }

    static func setAutomaticUpdatesEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: automaticUpdatesEnabledKey)
        defaults.set(true, forKey: migrationCompletedKey)
    }

    static func suppressedBuild(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: suppressedBuildKey)
    }

    static func setSuppressedBuild(_ build: String?, defaults: UserDefaults = .standard) {
        if let build {
            defaults.set(build, forKey: suppressedBuildKey)
        } else {
            defaults.removeObject(forKey: suppressedBuildKey)
        }
    }

    static func readyMetadata(defaults: UserDefaults = .standard) -> UpdateReadyMetadata? {
        guard let data = defaults.data(forKey: readyMetadataKey) else { return nil }
        return try? JSONDecoder().decode(UpdateReadyMetadata.self, from: data)
    }

    static func setReadyMetadata(
        _ metadata: UpdateReadyMetadata?,
        defaults: UserDefaults = .standard
    ) {
        guard let metadata, let data = try? JSONEncoder().encode(metadata) else {
            defaults.removeObject(forKey: readyMetadataKey)
            return
        }
        defaults.set(data, forKey: readyMetadataKey)
    }
}

struct UpdateReadyMetadata: Codable, Equatable {
    static let lifetime: TimeInterval = 48 * 60 * 60

    let version: String
    let build: String
    let readyAt: Date

    var expiresAt: Date {
        readyAt.addingTimeInterval(Self.lifetime)
    }

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

enum UpdateBuildPolicy {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = Int(lhs), let right = Int(rhs) {
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        }
        return lhs.compare(rhs, options: .numeric)
    }

    static func isSuppressed(candidateBuild: String, suppressedBuild: String?) -> Bool {
        guard let suppressedBuild else { return false }
        return compare(candidateBuild, suppressedBuild) != .orderedDescending
    }

    static func shouldClearSuppression(candidateBuild: String, suppressedBuild: String?) -> Bool {
        guard let suppressedBuild else { return false }
        return compare(candidateBuild, suppressedBuild) == .orderedDescending
    }

    static func isAlreadyInstalled(metadata: UpdateReadyMetadata, installedBuild: String?) -> Bool {
        guard let installedBuild, !installedBuild.isEmpty else { return false }
        return compare(metadata.build, installedBuild) != .orderedDescending
    }
}
