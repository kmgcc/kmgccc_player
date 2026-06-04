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
    /// Remote build number — the primary update signal. Compared against the local
    /// `CFBundleVersion`. May be absent in older fallback JSON, in which case the
    /// update decision falls back to semantic `latestVersion` comparison.
    let buildNumber: Int?
    let releaseURL: String
    let downloadURL: String?
    let notes: String
    let packageSizeBytes: Int64?
    let packageSHA256: String?

    enum CodingKeys: String, CodingKey {
        case latestVersion
        case releaseURL
        case notes
        case latestVersionSnake = "latest_version"
        case buildNumber = "build_number"
        case downloadURL = "download_url"
        case releaseNotesURL = "release_notes_url"
        case summary
        case packageSizeBytes = "package_size_bytes"
        case packageSHA256 = "package_sha256"
    }

    init(
        latestVersion: String,
        buildNumber: Int? = nil,
        releaseURL: String,
        downloadURL: String? = nil,
        notes: String,
        packageSizeBytes: Int64? = nil,
        packageSHA256: String? = nil
    ) {
        self.latestVersion = latestVersion
        self.buildNumber = buildNumber
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.notes = notes
        self.packageSizeBytes = packageSizeBytes
        self.packageSHA256 = packageSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
            ?? container.decode(String.self, forKey: .latestVersionSnake)
        buildNumber = Self.decodeBuildNumber(from: container)
        releaseURL = try container.decodeIfPresent(String.self, forKey: .releaseURL)
            ?? container.decodeIfPresent(String.self, forKey: .releaseNotesURL)
            ?? "https://github.com/kmgcc/kmgccc_player/releases/latest"
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
            ?? container.decodeIfPresent(String.self, forKey: .summary)
            ?? ""
        packageSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .packageSizeBytes)
        packageSHA256 = try container.decodeIfPresent(String.self, forKey: .packageSHA256)
    }

    /// `build_number` may arrive as a JSON number (GitHub Pages fallback) or a
    /// JSON string (backend config stores it as text). Parse both safely; never throw.
    private static func decodeBuildNumber(from container: KeyedDecodingContainer<CodingKeys>) -> Int? {
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: .buildNumber) {
            return intValue
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: .buildNumber) {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func resolvingRelativeURLs(baseURL: URL) -> RemoteVersionInfo {
        RemoteVersionInfo(
            latestVersion: latestVersion,
            buildNumber: buildNumber,
            releaseURL: Self.absoluteURLString(from: releaseURL, baseURL: baseURL) ?? releaseURL,
            downloadURL: downloadURL.flatMap { Self.absoluteURLString(from: $0, baseURL: baseURL) },
            notes: notes,
            packageSizeBytes: packageSizeBytes,
            packageSHA256: packageSHA256
        )
    }

    private static func absoluteURLString(from rawValue: String, baseURL: URL) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url.absoluteString
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString
    }
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

/// The signal used to decide whether a remote build is newer.
enum UpdateDecisionReason: Equatable {
    /// Decided by integer build-number comparison (preferred, monotonic).
    case buildNumber(local: Int, remote: Int)
    /// Decided by semantic `latest_version` comparison (fallback when build numbers
    /// are unavailable on either side — e.g. legacy fallback JSON).
    case semanticVersion
}

/// Outcome of an update availability decision.
struct UpdateDecision: Equatable {
    let isUpdateAvailable: Bool
    let reason: UpdateDecisionReason
}

enum UpdateAvailability {
    /// Decide whether the remote release is newer than the running app.
    ///
    /// Primary signal is the build number (`CFBundleVersion` vs remote `build_number`),
    /// which is monotonic and does not depend on remembering to bump the display
    /// version string. Falls back to semantic version comparison only when build
    /// numbers cannot be obtained from either side.
    static func decide(
        localBuild: Int?,
        remoteBuild: Int?,
        localVersion: String,
        remoteVersion: String
    ) -> UpdateDecision {
        if let localBuild, let remoteBuild {
            return UpdateDecision(
                isUpdateAvailable: remoteBuild > localBuild,
                reason: .buildNumber(local: localBuild, remote: remoteBuild)
            )
        }

        let comparison = VersionComparison.check(localVersion: localVersion, remoteVersion: remoteVersion)
        if case .newerAvailable = comparison {
            return UpdateDecision(isUpdateAvailable: true, reason: .semanticVersion)
        }
        return UpdateDecision(isUpdateAvailable: false, reason: .semanticVersion)
    }
}
