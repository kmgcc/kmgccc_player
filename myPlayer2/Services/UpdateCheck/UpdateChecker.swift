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

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.invalidResponse
        }

        let decodeResult = try RemoteVersionInfo.decodeResult(from: data)
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
}

enum UpdateError: Error {
    case invalidResponse
    case decodeError
}
