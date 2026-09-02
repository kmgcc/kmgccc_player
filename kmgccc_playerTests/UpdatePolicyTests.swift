import Foundation
import XCTest

final class UpdatePreferencesTests: XCTestCase {
    func testMigrationDefaultsAutomaticUpdatesToEnabled() {
        withDefaults { defaults in
            UpdatePreferences.migrateIfNeeded(defaults: defaults)

            XCTAssertTrue(
                UpdatePreferences.automaticUpdatesEnabled(defaults: defaults)
            )
            XCTAssertTrue(defaults.bool(forKey: UpdatePreferences.migrationCompletedKey))
        }
    }

    func testMigrationPreservesLegacyOptOut() {
        withDefaults { defaults in
            defaults.set(false, forKey: UpdatePreferences.legacyLaunchCheckKey)

            UpdatePreferences.migrateIfNeeded(defaults: defaults)

            XCTAssertFalse(
                UpdatePreferences.automaticUpdatesEnabled(defaults: defaults)
            )
        }
    }

    func testReadyMetadataExpiresAfterFortyEightHours() {
        let readyAt = Date(timeIntervalSince1970: 1_000)
        let metadata = UpdateReadyMetadata(
            version: "3.0",
            build: "12",
            readyAt: readyAt
        )

        XCTAssertFalse(
            metadata.isExpired(
                at: readyAt.addingTimeInterval(UpdateReadyMetadata.lifetime - 1)
            )
        )
        XCTAssertTrue(
            metadata.isExpired(
                at: readyAt.addingTimeInterval(UpdateReadyMetadata.lifetime)
            )
        )
    }

    func testHigherBuildClearsSuppressionButSameBuildDoesNot() {
        XCTAssertTrue(
            UpdateBuildPolicy.isSuppressed(
                candidateBuild: "12",
                suppressedBuild: "12"
            )
        )
        XCTAssertTrue(
            UpdateBuildPolicy.shouldClearSuppression(
                candidateBuild: "13",
                suppressedBuild: "12"
            )
        )
        XCTAssertFalse(
            UpdateBuildPolicy.shouldClearSuppression(
                candidateBuild: "11",
                suppressedBuild: "12"
            )
        )
    }

    func testInstalledBuildReconcilesReadyMetadata() {
        let metadata = UpdateReadyMetadata(
            version: "2.2.1",
            build: "12",
            readyAt: Date()
        )

        XCTAssertTrue(
            UpdateBuildPolicy.isAlreadyInstalled(metadata: metadata, installedBuild: "12")
        )
        XCTAssertTrue(
            UpdateBuildPolicy.isAlreadyInstalled(metadata: metadata, installedBuild: "13")
        )
        XCTAssertFalse(
            UpdateBuildPolicy.isAlreadyInstalled(metadata: metadata, installedBuild: "11")
        )
    }

    func testOmittedChannelResolvesAsProduction() throws {
        let environment = try UpdateEnvironment.resolve(info: productionEnvironmentInfo())

        XCTAssertEqual(environment.releaseChannel, .production)
        XCTAssertEqual(environment.allowedSparkleChannels, [])
        XCTAssertEqual(
            environment.primaryFeedURL.absoluteString,
            "https://updates.example.com/appcast.xml"
        )
    }

    func testCompleteTestEnvironmentUsesOnlyDedicatedValues() throws {
        var info = productionEnvironmentInfo()
        info[UpdateEnvironment.releaseChannelKey] = "test"
        info[UpdateEnvironment.testPrimaryFeedURLKey] =
            "https://updates.example.com/api/v1/updates/test/appcast.xml"
        info[UpdateEnvironment.testFallbackFeedURLKey] =
            "https://fallback.example.com/test/appcast.xml"
        info[UpdateEnvironment.testPublicKeyKey] = "test-public-key"
        info[UpdateEnvironment.primaryFeedURLKey] =
            info[UpdateEnvironment.testPrimaryFeedURLKey]
        info[UpdateEnvironment.fallbackFeedURLKey] =
            info[UpdateEnvironment.testFallbackFeedURLKey]
        info[UpdateEnvironment.publicKeyKey] = info[UpdateEnvironment.testPublicKeyKey]
        info[UpdateEnvironment.bundleIdentifierKey] = "kmgccc.player.test"
        info[UpdateEnvironment.displayNameKey] = "kmgccc_player Test"

        let environment = try UpdateEnvironment.resolve(info: info)

        XCTAssertEqual(environment.releaseChannel, .test)
        XCTAssertEqual(environment.allowedSparkleChannels, ["test"])
        XCTAssertEqual(environment.publicKey, "test-public-key")
        XCTAssertTrue(environment.primaryFeedURL.path.contains("/test/"))
        XCTAssertTrue(environment.fallbackFeedURL.path.contains("/test/"))
    }

    func testTestEnvironmentFailsClosedWithoutDedicatedKey() {
        var info = productionEnvironmentInfo()
        info[UpdateEnvironment.releaseChannelKey] = "test"
        info[UpdateEnvironment.testPrimaryFeedURLKey] =
            "https://updates.example.com/api/v1/updates/test/appcast.xml"
        info[UpdateEnvironment.testFallbackFeedURLKey] =
            "https://fallback.example.com/test/appcast.xml"

        XCTAssertThrowsError(try UpdateEnvironment.resolve(info: info)) { error in
            XCTAssertEqual(
                error as? UpdateEnvironmentError,
                .missingValue(UpdateEnvironment.testPublicKeyKey)
            )
        }
    }

    func testTestEnvironmentRejectsProductionSparkleExpansion() {
        var info = productionEnvironmentInfo()
        info[UpdateEnvironment.releaseChannelKey] = "test"
        info[UpdateEnvironment.testPrimaryFeedURLKey] =
            "https://updates.example.com/api/v1/updates/test/appcast.xml"
        info[UpdateEnvironment.testFallbackFeedURLKey] =
            "https://fallback.example.com/test/appcast.xml"
        info[UpdateEnvironment.testPublicKeyKey] = "test-public-key"

        XCTAssertThrowsError(try UpdateEnvironment.resolve(info: info))
    }

    func testTestEnvironmentRejectsProductionKeyReuse() {
        var info = productionEnvironmentInfo()
        info[UpdateEnvironment.releaseChannelKey] = "test"
        info[UpdateEnvironment.testPrimaryFeedURLKey] =
            "https://updates.example.com/api/v1/updates/test/appcast.xml"
        info[UpdateEnvironment.testFallbackFeedURLKey] =
            "https://fallback.example.com/test/appcast.xml"
        info[UpdateEnvironment.testPublicKeyKey] = "production-public-key"
        info[UpdateEnvironment.primaryFeedURLKey] =
            info[UpdateEnvironment.testPrimaryFeedURLKey]
        info[UpdateEnvironment.fallbackFeedURLKey] =
            info[UpdateEnvironment.testFallbackFeedURLKey]
        info[UpdateEnvironment.publicKeyKey] = info[UpdateEnvironment.testPublicKeyKey]
        info[UpdateEnvironment.bundleIdentifierKey] = "kmgccc.player.test"
        info[UpdateEnvironment.displayNameKey] = "kmgccc_player Test"

        XCTAssertThrowsError(try UpdateEnvironment.resolve(info: info)) { error in
            XCTAssertEqual(error as? UpdateEnvironmentError, .productionKeyReuse)
        }
    }

    func testFallbackPolicyAllowsFeedAndNetworkFailures() {
        XCTAssertTrue(
            UpdateFallbackPolicy.shouldUseFallback(
                for: NSError(domain: "SUSparkleErrorDomain", code: 1000)
            )
        )
        XCTAssertTrue(
            UpdateFallbackPolicy.shouldUseFallback(
                for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            )
        )
        XCTAssertTrue(
            UpdateFallbackPolicy.shouldUseFallback(
                for: NSError(domain: "SUSparkleErrorDomain", code: 2001)
            )
        )
    }

    func testNoUpdateErrorIsRecognizedAsNormalTerminalOutcome() {
        XCTAssertTrue(
            UpdateFallbackPolicy.isNoUpdateFound(
                NSError(domain: "SUSparkleErrorDomain", code: 1001)
            )
        )
        XCTAssertFalse(
            UpdateFallbackPolicy.isNoUpdateFound(
                NSError(domain: "SUSparkleErrorDomain", code: 1000)
            )
        )
    }

    func testFallbackRecoveryIsBounded() {
        XCTAssertFalse(
            UpdateCheckRecoveryPolicy.hasExhaustedFallbackRetries(
                UpdateCheckRecoveryPolicy.maximumFallbackRetryAttempts - 1
            )
        )
        XCTAssertTrue(
            UpdateCheckRecoveryPolicy.hasExhaustedFallbackRetries(
                UpdateCheckRecoveryPolicy.maximumFallbackRetryAttempts
            )
        )
    }

    func testFallbackPolicyRejectsCancellationAuthenticationAndInstallFailures() {
        XCTAssertFalse(
            UpdateFallbackPolicy.shouldUseFallback(
                for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            )
        )
        XCTAssertFalse(
            UpdateFallbackPolicy.shouldUseFallback(
                for: NSError(domain: "SUSparkleErrorDomain", code: 4001)
            )
        )
        XCTAssertFalse(
            UpdateFallbackPolicy.shouldUseFallback(
                for: NSError(domain: "SUSparkleErrorDomain", code: 4007)
            )
        )
        XCTAssertFalse(
            UpdateFallbackPolicy.shouldUseFallback(
                for: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            )
        )
    }

    private func productionEnvironmentInfo() -> [String: Any] {
        [
            UpdateEnvironment.primaryFeedURLKey: "https://updates.example.com/appcast.xml",
            UpdateEnvironment.fallbackFeedURLKey: "https://fallback.example.com/appcast.xml",
            UpdateEnvironment.productionPublicKeyKey: "production-public-key",
            UpdateEnvironment.publicKeyKey: "production-public-key",
        ]
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "UpdatePreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
