//
//  UpdateChecker.swift
//  myPlayer2
//
//  kmgccc_player - Remote update checker service
//

import Foundation
import Combine

enum UpdateLinks {
    static let backendLatestEndpoint = URL(string: "https://player.kmgccc.cn/api/v1/updates/latest")!
    static let githubPagesVersionEndpoint = URL(string: "https://kmgcc.github.io/kmgccc_player/version.json")!
    static let githubReleaseURL = URL(string: "https://github.com/kmgcc/kmgccc_player/releases")!
}

enum UpdateCheckPreferences {
    static let checkForUpdatesOnLaunchKey = "checkForUpdatesOnLaunch"

    static var checkForUpdatesOnLaunch: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: checkForUpdatesOnLaunchKey) != nil else {
            return true
        }
        return defaults.bool(forKey: checkForUpdatesOnLaunchKey)
    }
}

/// Service for checking remote version updates
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    
    /// Remote version JSON URL
    private let primaryVersionURL = UpdateChecker.url(
        fromEnvironment: "KMGCCC_UPDATE_PRIMARY_URL",
        fallback: UpdateLinks.backendLatestEndpoint
    )
    private let fallbackVersionURL = UpdateChecker.url(
        fromEnvironment: "KMGCCC_UPDATE_FALLBACK_URL",
        fallback: UpdateLinks.githubPagesVersionEndpoint
    )
    
    /// Current app version (from bundle) — used for user-facing display only.
    var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Current app build number (`CFBundleVersion`) — the primary update signal.
    /// Returns nil if the bundle value is missing or non-numeric, in which case the
    /// update decision safely falls back to semantic version comparison.
    var localBuildNumber: Int? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    /// Fetched remote version info
    @Published private(set) var remoteInfo: RemoteVersionInfo?
    
    /// Error if fetch failed
    @Published private(set) var error: Error?
    
    /// Whether a check is in progress
    @Published private(set) var isChecking = false
    
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration)
    }()
    
    private init() {}

    private static func url(fromEnvironment key: String, fallback: URL) -> URL {
        if let rawValue = ProcessInfo.processInfo.environment[key],
           let url = URL(string: rawValue) {
            return url
        }
        return fallback
    }
    
    /// Check for updates from remote
    func checkForUpdates() async {
        isChecking = true
        error = nil
        remoteInfo = nil
        
        do {
            let decodeResult = try await fetchVersionInfo()
            let info = decodeResult.info
            self.remoteInfo = info
            
            if decodeResult.usedSanitizedJSON {
                print("[UpdateChecker] ⚠️ Remote version.json was malformed; recovered by escaping raw control characters in strings")
                recordUpdateDiagnostic(
                    level: .warning,
                    category: .parse,
                    stage: .parse,
                    endpointType: "unknown",
                    messageCode: "json_repaired_control_chars",
                    context: [
                        "operation": .string("parse"),
                        "response_parse_error_code": .string("json_repaired_control_chars"),
                        "current_build_number": localBuildNumber.map { .int($0) } ?? .string("unknown"),
                        "latest_build_number_present": .bool(info.buildNumber != nil),
                        "download_url_present": .bool(info.downloadURL != nil)
                    ]
                )
            }

            if info.buildNumber == nil {
                recordUpdateDiagnostic(
                    level: .warning,
                    category: .validation,
                    stage: .response,
                    endpointType: "unknown",
                    messageCode: "build_number_missing",
                    context: [
                        "operation": .string("compare"),
                        "current_build_number": localBuildNumber.map { .int($0) } ?? .string("unknown"),
                        "latest_build_number_present": .bool(false),
                        "download_url_present": .bool(info.downloadURL != nil)
                    ]
                )
            }

            if info.downloadURL == nil {
                recordUpdateDiagnostic(
                    level: .warning,
                    category: .validation,
                    stage: .response,
                    endpointType: "unknown",
                    messageCode: "download_url_missing",
                    context: [
                        "operation": .string("download_metadata"),
                        "current_build_number": localBuildNumber.map { .int($0) } ?? .string("unknown"),
                        "latest_build_number_present": .bool(info.buildNumber != nil),
                        "download_url_present": .bool(false)
                    ]
                )
            }
            
            // Log for debugging
            print("[UpdateChecker] ✅ Remote version fetched:")
            print("  - latestVersion: \(info.latestVersion)")
            print("  - buildNumber: \(info.buildNumber.map(String.init) ?? "nil")")
            print("  - releaseURL: \(info.releaseURL)")
            print("  - notes: \(info.notes)")
            print("  - localVersion: \(localVersion) (build \(localBuildNumber.map(String.init) ?? "nil"))")

            // Perform update decision and log result
            let decision = UpdateAvailability.decide(
                localBuild: localBuildNumber,
                remoteBuild: info.buildNumber,
                localVersion: localVersion,
                remoteVersion: info.latestVersion
            )
            switch decision.reason {
            case .buildNumber(let local, let remote):
                print("[UpdateChecker] \(decision.isUpdateAvailable ? "⬆️ New build available" : "✓ Up to date") by build: \(local) → \(remote)")
            case .semanticVersion:
                print("[UpdateChecker] \(decision.isUpdateAvailable ? "⬆️ New version available" : "✓ Up to date") by semantic version (no build_number)")
            }

        } catch {
            self.error = error
            print("[UpdateChecker] ❌ Failed to fetch version: \(error)")
        }
        
        isChecking = false
    }

    private func fetchVersionInfo() async throws -> RemoteVersionInfoDecodeResult {
        do {
            let result = try await fetchVersionInfo(from: primaryVersionURL, cacheBust: false)
            print("[UpdateChecker] ✅ Primary update endpoint succeeded")
            return result
        } catch {
            print("[UpdateChecker] ⚠️ Primary update endpoint failed, falling back to GitHub Pages: \(error)")
            do {
                let result = try await fetchVersionInfo(from: fallbackVersionURL, cacheBust: true)
                print("[UpdateChecker] ✅ GitHub Pages fallback succeeded")
                return result
            } catch {
                print("[UpdateChecker] ❌ GitHub Pages fallback failed: \(error)")
                throw error
            }
        }
    }

    private func fetchVersionInfo(from url: URL, cacheBust: Bool) async throws -> RemoteVersionInfoDecodeResult {
        let started = ContinuousClock.now
        let endpointType = Self.endpointType(for: url)
        let requestURL: URL
        if cacheBust {
            let timestamp = Int(Date().timeIntervalSince1970)
            requestURL = url.appending(queryItems: [
                URLQueryItem(name: "t", value: String(timestamp))
            ])
        } else {
            requestURL = url
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = cacheBust ? 6 : 4
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            recordUpdateDiagnostic(
                level: .error,
                category: .network,
                stage: .request,
                endpointType: endpointType,
                messageCode: DiagnosticsErrorMapper.code(for: error),
                context: [
                    "operation": .string("check"),
                    "endpoint_type": .string(endpointType),
                    "network_error_code": .string(DiagnosticsErrorMapper.code(for: error)),
                    "duration_ms_bucket": .string(DiagnosticsBuckets.durationMs(Self.durationMilliseconds(since: started))),
                    "current_build_number": localBuildNumber.map { .int($0) } ?? .string("unknown")
                ]
            )
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            recordUpdateDiagnostic(
                level: .error,
                category: .network,
                stage: .response,
                endpointType: endpointType,
                messageCode: "missing_http_response",
                context: [
                    "operation": .string("check"),
                    "endpoint_type": .string(endpointType),
                    "network_error_code": .string("missing_http_response"),
                    "duration_ms_bucket": .string(DiagnosticsBuckets.durationMs(Self.durationMilliseconds(since: started))),
                    "current_build_number": localBuildNumber.map { .int($0) } ?? .string("unknown")
                ]
            )
            throw UpdateError.invalidResponse(statusCode: nil)
        }

        guard httpResponse.statusCode == 200 else {
            recordUpdateDiagnostic(
                level: .error,
                category: .network,
                stage: .response,
                endpointType: endpointType,
                messageCode: "http_status_error",
                context: [
                    "operation": .string("check"),
                    "endpoint_type": .string(endpointType),
                    "http_status": .int(httpResponse.statusCode),
                    "duration_ms_bucket": .string(DiagnosticsBuckets.durationMs(Self.durationMilliseconds(since: started))),
                    "current_build_number": localBuildNumber.map { .int($0) } ?? .string("unknown")
                ]
            )
            throw UpdateError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        let decodeResult: RemoteVersionInfoDecodeResult
        do {
            decodeResult = try RemoteVersionInfo.decodeResult(from: data)
        } catch {
            recordUpdateDiagnostic(
                level: .error,
                category: .parse,
                stage: .parse,
                endpointType: endpointType,
                messageCode: DiagnosticsErrorMapper.code(for: error),
                context: [
                    "operation": .string("parse"),
                    "endpoint_type": .string(endpointType),
                    "response_parse_error_code": .string(DiagnosticsErrorMapper.code(for: error)),
                    "duration_ms_bucket": .string(DiagnosticsBuckets.durationMs(Self.durationMilliseconds(since: started))),
                    "current_build_number": localBuildNumber.map { .int($0) } ?? .string("unknown")
                ]
            )
            throw error
        }
        let baseURL = httpResponse.url ?? requestURL
        return RemoteVersionInfoDecodeResult(
            info: decodeResult.info.resolvingRelativeURLs(baseURL: baseURL),
            usedSanitizedJSON: decodeResult.usedSanitizedJSON
        )
    }
    
    /// Check if update should be shown based on version comparison
    /// - Parameter forceShow: If true, always returns true regardless of version (for testing)
    func shouldShowUpdate(forceShow: Bool = false) -> Bool {
        if forceShow {
            return true
        }
        
        guard let remoteInfo = remoteInfo else {
            return false
        }

        // Primary: build-number comparison; falls back to semantic version when
        // build numbers are unavailable (older fallback JSON).
        return UpdateAvailability.decide(
            localBuild: localBuildNumber,
            remoteBuild: remoteInfo.buildNumber,
            localVersion: localVersion,
            remoteVersion: remoteInfo.latestVersion
        ).isUpdateAvailable
    }

    private func recordUpdateDiagnostic(
        level: DiagnosticsLevel,
        category: DiagnosticsCategory,
        stage: DiagnosticsStage,
        endpointType: String,
        messageCode: String,
        context: DiagnosticsContext
    ) {
        var safeContext = context
        safeContext["update_channel"] = .string("stable")
        safeContext["endpoint_type"] = .string(endpointType)
        DiagnosticsService.shared.record(
            level: level,
            subsystem: .update,
            category: category,
            stage: stage,
            provider: endpointType == "backend" ? .backend : .unknown,
            messageCode: messageCode,
            context: safeContext
        )
    }

    private static func endpointType(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "unknown" }
        if host.contains("player.kmgccc.cn") { return "backend" }
        if host.contains("github.io") { return "github_pages" }
        return "unknown"
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

enum UpdateError: Error {
    case invalidResponse(statusCode: Int?)
    case decodeError
}
