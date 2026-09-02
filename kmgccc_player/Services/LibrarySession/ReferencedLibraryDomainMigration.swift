//
//  ReferencedLibraryDomainMigration.swift
//  kmgccc_player
//
//  Crash-safe journal and backup boundary for referenced-library sidecars.
//

import Foundation

nonisolated enum ReferencedLibraryDomainMigrationStage: String, Codable, Sendable {
    case backedUp
    case committed
}

nonisolated struct ReferencedLibraryDomainMigrationJournal: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let libraryID: UUID
    let backupID: UUID
    let startedAt: Date
    var completedAt: Date?
    var stage: ReferencedLibraryDomainMigrationStage

    init(
        libraryID: UUID,
        backupID: UUID,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        stage: ReferencedLibraryDomainMigrationStage
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.libraryID = libraryID
        self.backupID = backupID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.stage = stage
    }
}

/// Owns the durable boundary around the referenced-library model transition.
/// The service deliberately does not restore files automatically: a crash
/// after the backup is recoverable, while an automatic restore could discard a
/// user's legitimate edit made between launches. A later maintenance command
/// can inspect the journal and choose an explicit rollback.
actor ReferencedLibraryDomainMigration {
    nonisolated let paths: LibraryPaths
    nonisolated let libraryID: UUID
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        paths: LibraryPaths,
        libraryID: UUID,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.libraryID = libraryID
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Creates one backup per library transition and returns the journal. A
    /// committed journal is idempotent, so reopening a library never copies
    /// its entire source tree again.
    func prepare() throws -> ReferencedLibraryDomainMigrationJournal {
        try fileManager.createDirectory(at: paths.settingsRootURL, withIntermediateDirectories: true)
        if let existing = try loadJournal() {
            guard existing.libraryID == libraryID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return existing
        }

        let backupID = UUID()
        let backupRoot = paths.domainMigrationBackupRootURL.appendingPathComponent(
            backupID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        for entry in backupEntries {
            try copyIfPresent(
                entry.source,
                to: backupRoot.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            )
        }

        let journal = ReferencedLibraryDomainMigrationJournal(
            libraryID: libraryID,
            backupID: backupID,
            stage: .backedUp
        )
        try persist(journal)
        return journal
    }

    func commit() throws {
        guard var journal = try loadJournal() else { return }
        guard journal.libraryID == libraryID else { throw CocoaError(.fileReadCorruptFile) }
        guard journal.stage != .committed else { return }
        journal.stage = .committed
        journal.completedAt = Date()
        try persist(journal)
    }

    func journal() throws -> ReferencedLibraryDomainMigrationJournal? {
        try loadJournal()
    }

    /// True only when a previous run durably committed this library's domain
    /// transition, so opening without a fresh backup protects nothing left to
    /// migrate. Any journal read failure counts as unknown and lets callers
    /// fail closed.
    func hasCommittedJournal() -> Bool {
        guard let journal = try? loadJournal() else { return false }
        return journal.libraryID == libraryID && journal.stage == .committed
    }

    /// Explicit maintenance hook for a caller that has stopped the library
    /// session and intentionally chosen to restore the pre-migration snapshot.
    /// It is never called automatically: restoring a backup over a later user
    /// edit would be more dangerous than leaving a journal pending.
    func restorePreparedState() throws {
        guard let journal = try loadJournal(), journal.libraryID == libraryID else { return }
        guard journal.stage == .backedUp else {
            throw CocoaError(.fileWriteFileExists)
        }
        let backupRoot = paths.domainMigrationBackupRootURL
            .appendingPathComponent(journal.backupID.uuidString, isDirectory: true)
        for entry in backupEntries {
            let destination = entry.source
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            let backup = backupRoot.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            guard fileManager.fileExists(atPath: backup.path) else { continue }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: backup, to: destination)
        }
    }

    private func loadJournal() throws -> ReferencedLibraryDomainMigrationJournal? {
        guard fileManager.fileExists(atPath: paths.domainMigrationJournalURL.path) else { return nil }
        let journal = try decoder.decode(
            ReferencedLibraryDomainMigrationJournal.self,
            from: Data(contentsOf: paths.domainMigrationJournalURL)
        )
        guard journal.schemaVersion == ReferencedLibraryDomainMigrationJournal.currentSchemaVersion else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return journal
    }

    private func persist(_ journal: ReferencedLibraryDomainMigrationJournal) throws {
        try encoder.encode(journal).write(to: paths.domainMigrationJournalURL, options: .atomic)
    }

    private var backupEntries: [(name: String, source: URL, isDirectory: Bool)] {
        [
            ("Manifest.json", paths.manifestURL, false),
            ("Tracks", paths.tracksRootURL, true),
            ("Sources", paths.sourcesRootURL, true),
            ("Playlists", paths.playlistsRootURL, true),
            ("Artists", paths.artistsRootURL, true),
            ("Albums", paths.albumsRootURL, true),
            ("SourceScan", paths.sourceScanCacheRootURL, true),
            ("LibraryScan", paths.libraryScanCacheRootURL, true),
        ]
    }

    private func copyIfPresent(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.copyItem(at: source, to: destination)
    }
}
