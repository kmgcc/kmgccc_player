//
//  TrackMediaLocator.swift
//  myPlayer2
//
//  Explicit on-disk contract for local media placement.
//

import Foundation

nonisolated enum LocalTrackStorageKind: String, Codable, Sendable {
    case managed
    case referenced
}

nonisolated enum TrackMediaLocator: Codable, Sendable, Equatable {
    case managed(libraryRelativePath: String)
    case referenced(ReferencedFileLocator)

    var storageKind: LocalTrackStorageKind {
        switch self {
        case .managed: return .managed
        case .referenced: return .referenced
        }
    }

    var managedLibraryRelativePath: String? {
        guard case let .managed(path) = self else { return nil }
        return path
    }

    var referencedFile: ReferencedFileLocator? {
        guard case let .referenced(locator) = self else { return nil }
        return locator
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case managed
        case referenced
    }

    enum ManagedCodingKeys: String, CodingKey {
        case libraryRelativePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(LocalTrackStorageKind.self, forKey: .kind)
        switch kind {
        case .managed:
            guard !container.contains(.referenced) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .referenced,
                    in: container,
                    debugDescription: "Managed locator must not contain referenced payload"
                )
            }
            let payload = try container.nestedContainer(
                keyedBy: ManagedCodingKeys.self,
                forKey: .managed
            )
            let path = try payload.decode(String.self, forKey: .libraryRelativePath)
            guard Self.isSafeRelativePath(path) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .libraryRelativePath,
                    in: payload,
                    debugDescription: "Managed locator contains an unsafe relative path"
                )
            }
            self = .managed(libraryRelativePath: path)
        case .referenced:
            guard !container.contains(.managed) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .managed,
                    in: container,
                    debugDescription: "Referenced locator must not contain managed payload"
                )
            }
            let locator = try container.decode(ReferencedFileLocator.self, forKey: .referenced)
            guard !locator.fileBookmarkData.isEmpty || !locator.sourceMemberships.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .referenced,
                    in: container,
                    debugDescription: "Referenced locator requires a bookmark or source membership"
                )
            }
            guard locator.sourceMemberships.allSatisfy({ Self.isSafeRelativePath($0.relativePath) }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .referenced,
                    in: container,
                    debugDescription: "Referenced locator contains an unsafe source-relative path"
                )
            }
            if let primarySourceID = locator.primarySourceID,
               !locator.sourceMemberships.contains(where: { $0.sourceID == primarySourceID }) {
                throw DecodingError.dataCorruptedError(
                    forKey: .referenced,
                    in: container,
                    debugDescription: "Primary source is not present in source memberships"
                )
            }
            self = .referenced(locator)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .managed(path):
            guard Self.isSafeRelativePath(path) else {
                throw EncodingError.invalidValue(
                    path,
                    .init(codingPath: encoder.codingPath, debugDescription: "Unsafe managed relative path")
                )
            }
            try container.encode(LocalTrackStorageKind.managed, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: ManagedCodingKeys.self, forKey: .managed)
            try payload.encode(path, forKey: .libraryRelativePath)
        case let .referenced(locator):
            guard !locator.fileBookmarkData.isEmpty || !locator.sourceMemberships.isEmpty,
                  locator.sourceMemberships.allSatisfy({ Self.isSafeRelativePath($0.relativePath) }),
                  locator.primarySourceID.map({ primary in
                      locator.sourceMemberships.contains(where: { $0.sourceID == primary })
                  }) ?? true
            else {
                throw EncodingError.invalidValue(
                    locator,
                    .init(codingPath: encoder.codingPath, debugDescription: "Invalid referenced locator")
                )
            }
            try container.encode(LocalTrackStorageKind.referenced, forKey: .kind)
            try container.encode(locator, forKey: .referenced)
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}
