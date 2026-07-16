import Foundation
import XCTest

final class CrashReportSanitizerTests: XCTestCase {
    func testKeepsLibraryRelativePathAndRemovesExternalPathDetails() {
        let root = URL(fileURLWithPath: "/Users/example/Music Library", isDirectory: true)
        let sanitizer = CrashReportSanitizer(
            libraryRootURL: root,
            appDataRootURL: URL(fileURLWithPath: "/Users/example/Library/Application Support/player", isDirectory: true)
        )
        var report = makeCrashReport()
        report.exception.reason = "token=secret-value while opening /Users/example/Documents/private-demo.flac"
        report.threads[0].frames[0].symbolName = "PlayerEngine.decodeFrame(at:)"
        report.breadcrumbs = [
            CrashBreadcrumb(
                occurredAt: Date(timeIntervalSince1970: 100),
                category: "library",
                action: "open_file",
                metadata: [
                    "path": .string("/Users/example/Music Library/Artist/Album/01 Song.flac"),
                    "externalPath": .string("/Users/example/Desktop/secret-demo.wav"),
                ]
            ),
        ]

        let sanitized = sanitizer.sanitize(report)

        XCTAssertEqual(
            sanitized.breadcrumbs[0].metadata["path"],
            .string("$MUSIC_LIBRARY/Artist/Album/01 Song.flac")
        )
        XCTAssertEqual(
            sanitized.breadcrumbs[0].metadata["externalPath"],
            .string("<EXTERNAL_PATH ext=.wav depth=4>")
        )
        XCTAssertEqual(sanitized.threads[0].frames[0].symbolName, "PlayerEngine.decodeFrame(at:)")
        XCTAssertFalse(sanitized.exception.reason?.contains("secret-value") == true)
        XCTAssertFalse(sanitized.exception.reason?.contains("private-demo") == true)
        XCTAssertGreaterThanOrEqual(sanitized.clientRedaction.replacementCounts["secret"] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(sanitized.clientRedaction.replacementCounts["external_path"] ?? 0, 1)
    }

    func testRejectsTraversalInPlaceholderPath() {
        let sanitizer = CrashReportSanitizer(
            libraryRootURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true),
            appDataRootURL: URL(fileURLWithPath: "/tmp/app", isDirectory: true)
        )
        var counts: [String: Int] = [:]

        let value = sanitizer.sanitizePath("$MUSIC_LIBRARY/../Documents/file.mp3", counts: &counts)

        XCTAssertEqual(value, "$MUSIC_LIBRARY/<INVALID_RELATIVE_PATH>")
        XCTAssertEqual(counts["invalid_placeholder_path"], 1)
    }
}

final class CrashReportStoreTests: XCTestCase {
    func testRoundTripsRecordAndUsesOneFilePerReport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrashReportStore(rootURL: root)
        let record = CrashReportRecord.pending(report: makeCrashReport())

        try await store.save(record)

        let savedRecord = await store.record(reportID: record.id)
        let savedRecords = await store.records()
        XCTAssertEqual(savedRecord, record)
        XCTAssertEqual(savedRecords, [record])
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Pending", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.map(\.pathExtension), ["json"])
    }

    func testQuarantinesMalformedRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let malformed = pending.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension("json")
        try Data("not-json".utf8).write(to: malformed)
        let store = CrashReportStore(rootURL: root)

        let records = await store.records()

        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformed.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Corrupt", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantined.count, 1)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportStoreTests-(UUID().uuidString)", isDirectory: true)
    }
}

final class CrashReportDeliveryModelTests: XCTestCase {
    func testAutomaticUploadDefaultsToEnabledAndCanBeDisabled() {
        let suiteName = "CrashReportPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(CrashReportPreferences.automaticUploadEnabled(defaults: defaults))
        defaults.set(false, forKey: CrashReportPreferences.automaticUploadKey)
        XCTAssertFalse(CrashReportPreferences.automaticUploadEnabled(defaults: defaults))
    }

    func testRetryDelayIncreasesAndIsCapped() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = CrashRetryPolicy.nextRetryDate(
            reportID: "922da39a-7985-41d9-8664-5dd613e292ed",
            attemptCount: 1,
            now: now
        )
        let fourth = CrashRetryPolicy.nextRetryDate(
            reportID: "922da39a-7985-41d9-8664-5dd613e292ed",
            attemptCount: 4,
            now: now
        )
        let capped = CrashRetryPolicy.nextRetryDate(
            reportID: "922da39a-7985-41d9-8664-5dd613e292ed",
            attemptCount: 99,
            now: now
        )

        XCTAssertGreaterThan(fourth, first)
        XCTAssertLessThanOrEqual(capped.timeIntervalSince(now), 21_630)
    }

    func testDeliveryRecordRoundTripsNewPermanentFailureState() throws {
        var record = CrashReportRecord.pending(report: makeCrashReport())
        record.technicalUploadState = .permanentlyFailed
        record.lastErrorCategory = "http_422_permanent"

        let data = try JSONEncoder.crashReportEncoder().encode(record)
        let decoded = try JSONDecoder.crashReportDecoder().decode(CrashReportRecord.self, from: data)

        XCTAssertEqual(decoded, record)
    }
}

final class MetricKitDiagnosticTests: XCTestCase {
    func testSanitizerRemovesExternalPathsSecretsAndURLDetails() throws {
        let input = Data(#"{"callStackTree":{"callStackPerThread":true,"binaryName":"/Users/alice/Desktop/My Song.flac"},"reason":"token=secret-value https://example.com/path?user=alice","symbol":"Player.openTrack()"}"#.utf8)

        let result = try MetricKitDiagnosticSanitizer.sanitize(input)

        XCTAssertFalse(result.json.contains("alice"))
        XCTAssertFalse(result.json.contains("secret-value"))
        XCTAssertFalse(result.json.contains("?user="))
        XCTAssertTrue(result.json.contains("Player.openTrack()"))
        XCTAssertGreaterThan(result.counts["externalPath"] ?? 0, 0)
    }

    func testMetricKitStoreDeduplicatesStableReportID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetricKitDiagnosticStore(rootURL: root, maxRecords: 5, maxBytes: 1_000_000)
        let envelope = MetricKitDiagnosticEnvelope(
            schemaVersion: 1,
            reportID: "8ff5d778-eedf-54c5-9ac7-5b961f3fa6f1",
            anonymousInstallID: "install-test",
            diagnosticKind: .hang,
            intervalBegin: Date(timeIntervalSince1970: 10),
            intervalEnd: Date(timeIntervalSince1970: 20),
            appVersion: "2.2.0",
            buildNumber: "8",
            architecture: "arm64",
            osVersion: "macOS 26.0",
            deviceType: "Mac",
            payloadJSON: "{}",
            clientRedactionVersion: "1",
            clientRedactionCounts: [:],
            uploadMode: "automatic"
        )
        let record = MetricKitDiagnosticRecord(
            envelope: envelope,
            attemptCount: 0,
            nextRetryAt: nil,
            lastErrorCategory: nil
        )

        try await store.insertIfNeeded(record)
        try await store.insertIfNeeded(record)

        let records = await store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, envelope.reportID)
    }
}

private func makeCrashReport() -> CrashReportEnvelope {
    let reportID = "922da39a-7985-41d9-8664-5dd613e292ed"
    return CrashReportEnvelope(
        schemaVersion: 1,
        reportID: reportID,
        anonymousInstallID: "install-test",
        sessionID: "session-test",
        occurredAt: Date(timeIntervalSince1970: 100),
        importedAt: Date(timeIntervalSince1970: 101),
        app: CrashAppInfo(
            bundleID: "com.example.player",
            version: "1.0",
            build: "1",
            architecture: "arm64",
            executableUUID: "A1B2C3"
        ),
        system: CrashSystemInfo(osVersion: "macOS 26.0", modelIdentifier: nil, locale: "en_US"),
        process: CrashProcessInfo(uptimeSeconds: 42),
        exception: CrashExceptionInfo(
            signal: "SIGABRT",
            machType: nil,
            machCode: nil,
            machSubcode: nil,
            name: "NSInternalInconsistencyException",
            reason: "test"
        ),
        threads: [
            CrashThread(
                index: 0,
                id: "1",
                name: "main",
                queueName: "com.apple.main-thread",
                isCrashed: true,
                frames: [
                    CrashFrame(
                        instructionAddress: "0x100001000",
                        imageUUID: "A1B2C3",
                        imageName: "kmgccc_player",
                        imageBaseAddress: "0x100000000",
                        imageRelativeAddress: "0x1000",
                        symbolName: "main",
                        symbolOffset: 4
                    ),
                ]
            ),
        ],
        crashedThread: CrashRegisterSet(threadIndex: 0, values: ["pc": "0x100001000"]),
        binaryImages: [
            CrashBinaryImage(
                uuid: "A1B2C3",
                basename: "kmgccc_player",
                architecture: "arm64",
                loadAddress: "0x100000000",
                size: 4_096,
                version: "1.0"
            ),
        ],
        appContext: CrashAppContext(
            playbackSourceCategory: "local",
            isPlaying: true,
            visibleSurface: "main_window",
            isFullScreen: false,
            selectedSkinIdentifier: nil,
            lastOperationCategory: "play"
        ),
        breadcrumbs: [],
        clientRedaction: CrashRedactionInfo(version: "0", replacementCounts: [:]),
        uploadMode: .automatic,
        userDescription: nil
    )
}
