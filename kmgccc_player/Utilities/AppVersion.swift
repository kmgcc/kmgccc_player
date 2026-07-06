//
//  AppVersion.swift
//  myPlayer2
//
//  kmgccc_player - App version/build helpers
//

import Foundation

/// Monotonic app build number (`CFBundleVersion`).
///
/// Use this for internal release gates: update checks, What's New seen state,
/// Feature Tip introduction gates, and one-time migrations.
struct AppBuild: Comparable, Codable, Hashable {
    static let legacyBaseline = AppBuild(0)

    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    init?(from string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else { return nil }
        self.rawValue = value
    }

    static var current: AppBuild {
        let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return buildString.flatMap { AppBuild(from: $0) } ?? .legacyBaseline
    }

    var stringValue: String {
        String(rawValue)
    }

    static func < (lhs: AppBuild, rhs: AppBuild) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension AppBuild: CustomStringConvertible {
    var description: String {
        stringValue
    }
}

/// Marketing version (`CFBundleShortVersionString`).
///
/// Keep this for UI display and APIs that require a semantic version object.
/// Do not use it for release-state decisions.
struct AppVersion: Comparable, Codable {
    
    let major: Int
    let minor: Int
    let patch: Int
    
    init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    
    init?(from string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)

        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        var components: [Int] = []
        components.reserveCapacity(3)

        for part in parts {
            let segment = String(part)
            guard !segment.isEmpty,
                  segment.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                  let value = Int(segment) else {
                return nil
            }
            components.append(value)
        }

        self.major = components[0]
        self.minor = components.count > 1 ? components[1] : 0
        self.patch = components.count > 2 ? components[2] : 0
    }

    static var current: AppVersion {
        let versionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return versionString.flatMap { AppVersion(from: $0) } ?? AppVersion(major: 0)
    }
    
    var stringValue: String {
        "\(major).\(minor).\(patch)"
    }
    
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        return lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}

extension AppVersion: CustomStringConvertible {
    var description: String {
        return stringValue
    }
}
