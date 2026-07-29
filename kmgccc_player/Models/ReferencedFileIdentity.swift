//
//  ReferencedFileIdentity.swift
//  myPlayer2
//
//  Stable identity and source-membership values for referenced local files.
//

import Foundation

nonisolated struct ReferencedFileIdentity: Codable, Sendable, Hashable {
    var volumeUUID: String?
    var resourceIdentifierArchive: Data?

    enum CodingKeys: String, CodingKey {
        case volumeUUID
        case resourceIdentifierArchive
    }

    init(volumeUUID: String? = nil, resourceIdentifierArchive: Data? = nil) {
        self.volumeUUID = volumeUUID
        self.resourceIdentifierArchive = resourceIdentifierArchive
    }
}

nonisolated struct ReferencedFileFingerprint: Codable, Sendable, Equatable {
    var identity: ReferencedFileIdentity?
    var fileSize: Int64
    var modifiedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case identity
        case fileSize
        case modifiedAt
    }

    init(identity: ReferencedFileIdentity? = nil, fileSize: Int64, modifiedAt: TimeInterval) {
        self.identity = identity
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

nonisolated struct ReferencedSourceMembership: Codable, Sendable, Hashable {
    var sourceID: UUID
    var relativePath: String

    enum CodingKeys: String, CodingKey {
        case sourceID
        case relativePath
    }

    init(sourceID: UUID, relativePath: String) {
        self.sourceID = sourceID
        self.relativePath = relativePath
    }
}

nonisolated struct ReferencedFileLocator: Codable, Sendable, Equatable {
    var fileBookmarkData: Data
    var sourceMemberships: [ReferencedSourceMembership]
    var primarySourceID: UUID?
    var lastKnownPath: String
    var fingerprint: ReferencedFileFingerprint?
    var ncmSourceIdentity: ReferencedFileIdentity?

    enum CodingKeys: String, CodingKey {
        case fileBookmarkData
        case sourceMemberships
        case primarySourceID
        case lastKnownPath
        case fingerprint
        case ncmSourceIdentity
    }

    init(
        fileBookmarkData: Data,
        sourceMemberships: [ReferencedSourceMembership] = [],
        primarySourceID: UUID? = nil,
        lastKnownPath: String = "",
        fingerprint: ReferencedFileFingerprint? = nil,
        ncmSourceIdentity: ReferencedFileIdentity? = nil
    ) {
        self.fileBookmarkData = fileBookmarkData
        self.sourceMemberships = sourceMemberships
        self.primarySourceID = primarySourceID
        self.lastKnownPath = lastKnownPath
        self.fingerprint = fingerprint
        self.ncmSourceIdentity = ncmSourceIdentity
    }
}
