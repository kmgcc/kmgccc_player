//
//  RemoteVersionInfo.swift
//  myPlayer2
//
//  kmgccc_player - Remote version information model
//

import Foundation

/// Remote version information from version.json
struct RemoteVersionInfo: Decodable {
    let latestVersion: String
    let releaseURL: String
    let notes: String
}

/// Version comparison helper
enum VersionComparison {
    case newerAvailable(current: AppVersion, remote: AppVersion)
    case upToDate(current: AppVersion)
    case failedToParse

    /// Check if update is available
    static func check(localVersion: String, remoteVersion: String) -> VersionComparison {
        guard let local = AppVersion(from: localVersion),
              let remote = AppVersion(from: remoteVersion) else {
            return .failedToParse
        }

        if local < remote {
            return .newerAvailable(current: local, remote: remote)
        } else {
            return .upToDate(current: local)
        }
    }
}
