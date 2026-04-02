//
//  UpdateChecker.swift
//  myPlayer2
//
//  kmgccc_player - Remote update checker service
//

import Foundation
import Combine

/// Service for checking remote version updates
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    
    /// Remote version JSON URL
    private let versionURL = URL(string: "https://kmgcc.github.io/kmgccc_player/version.json")!
    
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
    
    private var cancellable: AnyCancellable?
    
    private init() {}
    
    /// Check for updates from remote
    func checkForUpdates() async {
        isChecking = true
        error = nil
        
        do {
            // Add timestamp to bypass GitHub Pages cache
            let timestamp = Int(Date().timeIntervalSince1970)
            let urlWithCache = versionURL.appending(queryItems: [
                URLQueryItem(name: "t", value: String(timestamp))
            ])
            
            let (data, response) = try await URLSession.shared.data(from: urlWithCache)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw UpdateError.invalidResponse
            }
            
            let info = try JSONDecoder().decode(RemoteVersionInfo.self, from: data)
            self.remoteInfo = info
            
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
