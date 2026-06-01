//
//  UpdateChecker.swift
//  myPlayer2
//
//  kmgccc_player - Remote update checker service
//

import Foundation
import Combine

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
        fallback: "https://player.kmgccc.cn/api/v1/updates/latest"
    )
    private let fallbackVersionURL = UpdateChecker.url(
        fromEnvironment: "KMGCCC_UPDATE_FALLBACK_URL",
        fallback: "https://kmgcc.github.io/kmgccc_player/version.json"
    )
    
    /// Current app version (from bundle)
    var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
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

    private static func url(fromEnvironment key: String, fallback: String) -> URL {
        if let rawValue = ProcessInfo.processInfo.environment[key],
           let url = URL(string: rawValue) {
            return url
        }
        return URL(string: fallback)!
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
            print("  - releaseURL: \(info.releaseURL)")
            print("  - notes: \(info.notes)")
            print("  - localVersion: \(localVersion)")
            
            // Perform version comparison and log result
            let comparison = VersionComparison.check(localVersion: localVersion, remoteVersion: info.latestVersion)
            switch comparison {
            case .newerAvailable(let current, let remote):
                print("[UpdateChecker] ⬆️ New version available: \(current) → \(remote)")
            case .upToDate(let current):
                print("[UpdateChecker] ✓ Already up to date: \(current)")
            case .failedToParse:
                print("[UpdateChecker] ⚠️ Failed to parse version strings")
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

        return try RemoteVersionInfo.decodeResult(from: data)
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
        
        let comparison = VersionComparison.check(localVersion: localVersion, remoteVersion: remoteInfo.latestVersion)
        if case .newerAvailable = comparison {
            return true
        }
        return false
    }
}

enum UpdateError: Error {
    case invalidResponse
    case decodeError
}
