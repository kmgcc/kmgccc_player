import Foundation
import PlayerAutomationProtocol

struct AutomationSelectionSnapshot: Codable, Equatable {
    let libraryID: UUID
    let summary: AutomationSelectionSummary
    let trackIDs: [UUID]
    let filter: AutomationJSONValue?
}

struct AutomationSelectionStoreFile: Codable {
    let schemaVersion: Int
    let snapshots: [AutomationSelectionSnapshot]
}

final class AutomationSelectionStore {
    private let appSupportURL: URL
    private let bundleIdentifier: String
    private let fileManager: FileManager
    private let maximumSnapshotCount = 100

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier
        appSupportURL = appSupportDirectoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    func load(libraryID: UUID, now: Date = Date()) throws -> [AutomationSelectionSnapshot] {
        let url = fileURL(for: libraryID)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let payload = try AutomationWireCoding.decoder().decode(
            AutomationSelectionStoreFile.self,
            from: data
        )
        guard payload.schemaVersion == 1,
              payload.snapshots.allSatisfy({ $0.libraryID == libraryID }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return payload.snapshots.filter { $0.summary.expiresAt > now }
    }

    func save(
        _ snapshots: [AutomationSelectionSnapshot],
        libraryID: UUID,
        now: Date = Date()
    ) throws {
        let normalized = snapshots
            .filter { $0.libraryID == libraryID && $0.summary.expiresAt > now }
            .sorted { $0.summary.createdAt > $1.summary.createdAt }
            .prefix(maximumSnapshotCount)
        let payload = AutomationSelectionStoreFile(
            schemaVersion: 1,
            snapshots: Array(normalized)
        )
        let directoryURL = fileURL(for: libraryID).deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let data = try AutomationWireCoding.encoder().encode(payload)
        let url = fileURL(for: libraryID)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func fileURL(for libraryID: UUID) -> URL {
        appSupportURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("Selections", isDirectory: true)
            .appendingPathComponent("\(libraryID.uuidString).json", isDirectory: false)
    }
}

/// The App-owned automation endpoint. It exposes DTOs only; no repository or
/// sidecar parser crosses the process boundary. CLI, MCP and future in-process
/// AI callers all reach the same App-owned capability handler.
