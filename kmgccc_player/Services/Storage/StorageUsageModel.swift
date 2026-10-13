//
//  StorageUsageModel.swift
//  kmgccc_player
//
//  State behind the Storage settings page: measurement and cleaning.
//

import Foundation
import Observation

@Observable
@MainActor
final class StorageUsageModel {
    private(set) var report: StorageUsageReport?
    private(set) var activeLibraryName: String?
    private(set) var otherLibraries: [InactiveLibraryUsage] = []
    private(set) var isMeasuring = false
    private(set) var busyCategories: Set<StorageCategory> = []
    private(set) var busyLibraryIDs: Set<UUID> = []

    /// Measures the open library, its external audio, the App's own data and
    /// every other registered library whose folder is reachable.
    func refresh(
        storage: LibraryStorageLocations,
        activeLibraryID: UUID,
        tracks: [Track],
        registry: MusicLibraryRegistry
    ) async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        activeLibraryName = registry.libraries.first { $0.id == activeLibraryID }?.displayName
        let externalAudio = Self.externalAudioFiles(in: tracks)
        let others = registry.libraries.filter { $0.id != activeLibraryID }
        let result = await Task.detached(priority: .utility) {
            let report = StorageUsageScanner.measure(storage: storage, externalAudio: externalAudio)
            let fileManager = FileManager.default
            let usages = others.compactMap { library -> InactiveLibraryUsage? in
                let rootURL = URL(fileURLWithPath: library.lastKnownPath, isDirectory: true)
                guard fileManager.fileExists(atPath: rootURL.path) else { return nil }
                return StorageUsageScanner.measureInactiveLibrary(
                    id: library.id,
                    displayName: library.displayName,
                    rootURL: rootURL
                )
            }
            return (report, usages)
        }.value
        report = result.0
        otherLibraries = result.1
    }

    func clear(_ categories: [StorageCategory], services: LibraryCacheServices) async {
        let pending = categories.filter { !busyCategories.contains($0) }
        guard !pending.isEmpty else { return }
        busyCategories.formUnion(pending)
        defer { busyCategories.subtract(pending) }
        for category in pending {
            await CacheManager.clear(category, services: services)
        }
    }

    func clearCaches(of library: InactiveLibraryUsage) async {
        guard busyLibraryIDs.insert(library.id).inserted else { return }
        defer { busyLibraryIDs.remove(library.id) }
        await CacheManager.clearInactiveLibraryCaches(rootURL: library.rootURL)
    }

    /// Every location of each referenced track, with the size its
    /// fingerprint recorded.
    private static func externalAudioFiles(in tracks: [Track]) -> [ExternalAudioFile] {
        tracks.flatMap { track -> [ExternalAudioFile] in
            guard case let .referenced(locator) = track.mediaLocator else { return [] }
            return locator.locations.map {
                ExternalAudioFile(path: $0.lastKnownPath, knownSize: $0.fingerprint?.fileSize)
            }
        }
    }
}
