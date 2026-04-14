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

struct RemoteVersionInfoDecodeResult {
    let info: RemoteVersionInfo
    let usedSanitizedJSON: Bool
}

extension RemoteVersionInfo {
    static func decodeResult(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws
        -> RemoteVersionInfoDecodeResult
    {
        do {
            let info = try decoder.decode(Self.self, from: data)
            return RemoteVersionInfoDecodeResult(info: info, usedSanitizedJSON: false)
        } catch {
            guard let repairedData = repairInvalidJSONStringControlCharacters(in: data) else {
                throw error
            }

            let info = try decoder.decode(Self.self, from: repairedData)
            return RemoteVersionInfoDecodeResult(info: info, usedSanitizedJSON: true)
        }
    }

    /// Some manually edited version.json files contain raw line breaks in string values.
    /// Escape those control characters so the update check can still recover.
    private static func repairInvalidJSONStringControlCharacters(in data: Data) -> Data? {
        guard let rawJSON = String(data: data, encoding: .utf8) else { return nil }

        let quote = UnicodeScalar(34)!
        let backslash = UnicodeScalar(92)!
        let lowercaseN = UnicodeScalar(110)!
        let lowercaseR = UnicodeScalar(114)!
        let lowercaseT = UnicodeScalar(116)!

        var repairedScalars = String.UnicodeScalarView()
        repairedScalars.reserveCapacity(rawJSON.unicodeScalars.count)

        var isInsideString = false
        var isEscaping = false
        var didModify = false

        for scalar in rawJSON.unicodeScalars {
            if isInsideString {
                if isEscaping {
                    repairedScalars.append(scalar)
                    isEscaping = false
                    continue
                }

                switch scalar {
                case backslash:
                    repairedScalars.append(scalar)
                    isEscaping = true
                case quote:
                    repairedScalars.append(scalar)
                    isInsideString = false
                case "\n":
                    repairedScalars.append(backslash)
                    repairedScalars.append(lowercaseN)
                    didModify = true
                case "\r":
                    repairedScalars.append(backslash)
                    repairedScalars.append(lowercaseR)
                    didModify = true
                case "\t":
                    repairedScalars.append(backslash)
                    repairedScalars.append(lowercaseT)
                    didModify = true
                default:
                    if scalar.value < 0x20 {
                        let escaped = String(format: "\\u%04X", scalar.value)
                        repairedScalars.append(contentsOf: escaped.unicodeScalars)
                        didModify = true
                    } else {
                        repairedScalars.append(scalar)
                    }
                }
            } else {
                repairedScalars.append(scalar)
                if scalar == quote {
                    isInsideString = true
                }
            }
        }

        guard didModify else { return nil }
        return String(repairedScalars).data(using: .utf8)
    }
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
