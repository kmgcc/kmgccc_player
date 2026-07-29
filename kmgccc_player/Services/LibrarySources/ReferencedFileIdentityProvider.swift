//
//  ReferencedFileIdentityProvider.swift
//  kmgccc_player
//

import Foundation

nonisolated enum ReferencedFileIdentityError: Error, Equatable {
    case notRegularFile
    case unavailable
}

nonisolated struct ReferencedFileIdentityProvider: Sendable {
    func fingerprint(for url: URL) throws -> ReferencedFileFingerprint {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .volumeUUIDStringKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true else { throw ReferencedFileIdentityError.notRegularFile }

        let archive: Data?
        if let data = values.fileResourceIdentifier as? Data {
            archive = data
        } else if let identifier = values.fileResourceIdentifier {
            archive = try? NSKeyedArchiver.archivedData(
                withRootObject: identifier,
                requiringSecureCoding: false
            )
        } else {
            archive = nil
        }
        let identity: ReferencedFileIdentity?
        if archive != nil {
            identity = ReferencedFileIdentity(
                volumeUUID: values.volumeUUIDString,
                resourceIdentifierArchive: archive
            )
        } else {
            identity = nil
        }
        guard let size = values.fileSize, let modifiedAt = values.contentModificationDate else {
            throw ReferencedFileIdentityError.unavailable
        }
        return ReferencedFileFingerprint(
            identity: identity,
            fileSize: Int64(size),
            modifiedAt: modifiedAt.timeIntervalSince1970
        )
    }
}

nonisolated struct ReferencedPhysicalIdentityKey: Hashable, Sendable {
    private enum Storage: Hashable, Sendable {
        case stable(ReferencedFileIdentity)
        case fingerprint(Int64, Int64)
    }

    private let storage: Storage

    init(_ fingerprint: ReferencedFileFingerprint) {
        if let identity = fingerprint.identity,
           identity.volumeUUID != nil,
           identity.resourceIdentifierArchive != nil {
            storage = .stable(identity)
        } else {
            storage = .fingerprint(
                fingerprint.fileSize,
                Int64((fingerprint.modifiedAt * 1_000_000).rounded())
            )
        }
    }
}
