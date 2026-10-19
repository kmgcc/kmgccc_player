//
//  StorageUsageScanner.swift
//  kmgccc_player
//
//  Measures what the App occupies on disk, grouped by `StorageCategory`.
//

import Foundation

nonisolated struct StorageUsageReport: Sendable, Equatable {
    var bytes: [StorageCategory: Int64] = [:]
    /// Free space on the volume that holds the library.
    var volumeAvailableBytes: Int64?

    func bytes(for category: StorageCategory) -> Int64 { bytes[category] ?? 0 }

    var totalBytes: Int64 { bytes.values.reduce(0, +) }

    var cleanableBytes: Int64 {
        StorageCategory.cacheCategories.reduce(0) { $0 + bytes(for: $1) }
    }
}

/// One audio file of a referenced library. `knownSize` comes from the
/// fingerprint stored with the track; the file is read only when it is
/// missing.
nonisolated struct ExternalAudioFile: Sendable, Hashable {
    let path: String
    let knownSize: Int64?
}

/// Size of a library that is not open, measured from its folder alone.
nonisolated struct InactiveLibraryUsage: Sendable, Equatable, Identifiable {
    let id: UUID
    let displayName: String
    let rootURL: URL
    let totalBytes: Int64
    let cleanableBytes: Int64
}

nonisolated enum StorageUsageScanner {
    /// Measures the open library, its external audio and the App's own data.
    static func measure(
        storage: LibraryStorageLocations,
        externalAudio: [ExternalAudioFile]
    ) -> StorageUsageReport {
        var report = StorageUsageReport()
        report.bytes = measureLibraryFolder(storage: storage)
        report.bytes[.externalMusic] = measureExternalAudio(externalAudio)
        report.bytes[.onlineCache, default: 0] += allocatedSize(of: AppStorageLocations.networkCacheURL)
        report.bytes[.appData] = AppStorageLocations.appDataURLs.reduce(0) { $0 + allocatedSize(of: $1) }
        report.volumeAvailableBytes = volumeAvailableBytes(at: storage.libraryRootURL)
        return report
    }

    static func measureInactiveLibrary(
        id: UUID,
        displayName: String,
        rootURL: URL
    ) -> InactiveLibraryUsage {
        let storage = StorageLocations.scoped(to: LibraryPaths(rootURL: rootURL))
        let bytes = measureLibraryFolder(storage: storage)
        return InactiveLibraryUsage(
            id: id,
            displayName: displayName,
            rootURL: rootURL,
            totalBytes: bytes.values.reduce(0, +),
            cleanableBytes: StorageCategory.cacheCategories.reduce(0) { $0 + (bytes[$1] ?? 0) }
        )
    }

    /// One walk over the library folder; each file is assigned by its path.
    static func measureLibraryFolder(storage: LibraryStorageLocations) -> [StorageCategory: Int64] {
        let classifier = LibraryPathClassifier(storage: storage)
        var bytes: [StorageCategory: Int64] = [:]
        let root = storage.libraryRootURL.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: sizeKeys,
            options: []
        ) else {
            return bytes
        }
        let rootPrefix = root.path + "/"
        for case let url as URL in enumerator {
            guard let size = regularFileSize(url) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else { continue }
            let category = classifier.category(forRelativePath: String(path.dropFirst(rootPrefix.count)))
            bytes[category, default: 0] += size
        }
        return bytes
    }

    static func allocatedSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: sizeKeys,
            options: []
        ) else {
            return regularFileSize(url) ?? 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += regularFileSize(child) ?? 0
        }
        return total
    }

    private static func measureExternalAudio(_ files: [ExternalAudioFile]) -> Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for file in files where seen.insert(file.path).inserted {
            if let known = file.knownSize, known > 0 {
                total += known
            } else {
                total += regularFileSize(URL(fileURLWithPath: file.path)) ?? 0
            }
        }
        return total
    }

    private static func volumeAvailableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static let sizeKeys: [URLResourceKey] = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
    ]

    private static func regularFileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: Set(sizeKeys)),
              values.isRegularFile == true else { return nil }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
}

/// Assigns a path inside a library folder to its storage category.
nonisolated struct LibraryPathClassifier: Sendable {
    private let areaPrefixes: [(prefix: String, category: StorageCategory)]
    private let retiredPrefixes: [String]
    private let cachePrefix: String
    private let indexPrefix: String
    private let tracksPrefix: String

    init(storage: LibraryStorageLocations) {
        let root = storage.libraryRootURL.standardizedFileURL.path + "/"
        func relative(_ url: URL) -> String {
            String(url.standardizedFileURL.path.dropFirst(root.count))
        }
        areaPrefixes = LibraryCacheArea.allCases
            .map { (relative($0.url(in: storage)) + "/", $0.category) }
            .sorted { $0.prefix.count > $1.prefix.count }
        retiredPrefixes = storage.paths.retiredDataURLs.map { relative($0) }
        cachePrefix = relative(storage.libraryCacheRootURL) + "/"
        indexPrefix = relative(storage.paths.indexRootURL) + "/"
        tracksPrefix = relative(storage.paths.tracksRootURL) + "/"
    }

    func category(forRelativePath path: String) -> StorageCategory {
        if path.hasPrefix(cachePrefix) {
            return areaPrefixes.first { path.hasPrefix($0.prefix) }?.category ?? .otherCache
        }
        if path.hasPrefix(indexPrefix) { return .indexes }
        if retiredPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .otherCache
        }
        // Managed audio is stored as `Tracks/<id>/audio.<ext>`; older
        // imports may keep the original file name.
        if path.hasPrefix(tracksPrefix), let name = path.split(separator: "/").last {
            let lowered = name.lowercased()
            let fileExtension = lowered.split(separator: ".").last.map(String.init) ?? ""
            if lowered.hasPrefix("audio.") || Self.audioExtensions.contains(fileExtension) {
                return .music
            }
        }
        return .libraryContent
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "alac", "wav", "aif", "aiff", "caf",
        "ogg", "oga", "opus", "ape", "wv", "wma", "dsf", "dff",
    ]
}
