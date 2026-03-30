//
//  AppVersion.swift
//  myPlayer2
//
//  kmgccc_player - Semantic version comparison utility
//

import Foundation

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
        let components = string.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        
        guard !components.isEmpty, components.count <= 3 else { return nil }
        
        self.major = components[0]
        self.minor = components.count > 1 ? components[1] : 0
        self.patch = components.count > 2 ? components[2] : 0
    }
    
    var stringValue: String {
        if patch == 0 && minor == 0 {
            return "\(major)"
        } else if patch == 0 {
            return "\(major).\(minor)"
        } else {
            return "\(major).\(minor).\(patch)"
        }
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