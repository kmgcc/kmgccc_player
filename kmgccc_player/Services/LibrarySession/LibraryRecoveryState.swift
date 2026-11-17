import Foundation

/// A persisted record of the last activation that could not be reconciled.
/// It exists so a crash or a second failure cannot leave the running session,
/// the registry selection, and the next launch without a common explanation.
nonisolated struct LibraryRecoveryState: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let recordedAt: Date
    let message: String
    let intendedLibraryID: UUID?
    let activeLibraryID: UUID?
    let hasLiveSession: Bool

    init(
        schemaVersion: Int = LibraryRecoveryState.schemaVersion,
        recordedAt: Date = Date(),
        message: String,
        intendedLibraryID: UUID?,
        activeLibraryID: UUID?,
        hasLiveSession: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.recordedAt = recordedAt
        self.message = message
        self.intendedLibraryID = intendedLibraryID
        self.activeLibraryID = activeLibraryID
        self.hasLiveSession = hasLiveSession
    }
}

nonisolated struct LibraryRecoveryStateStore {
    static func defaultURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "kmgccc.player"
    ) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("LibraryRecoveryState.json")
    }

    let fileURL: URL
    let fileManager: FileManager

    init(
        fileURL: URL = LibraryRecoveryStateStore.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() -> LibraryRecoveryState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(LibraryRecoveryState.self, from: data),
              state.schemaVersion == LibraryRecoveryState.schemaVersion else {
            // An unreadable recovery marker must not be treated as absent:
            // report it without guessing the library it referred to.
            return LibraryRecoveryState(
                message: "上次资料库恢复记录无法读取",
                intendedLibraryID: nil,
                activeLibraryID: nil,
                hasLiveSession: false
            )
        }
        return state
    }

    func save(_ state: LibraryRecoveryState) {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            Log.error("[LibraryRecovery] failed to persist recovery state: \(error)", category: .library)
        }
    }

    func clear() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do { try fileManager.removeItem(at: fileURL) }
        catch { Log.error("[LibraryRecovery] failed to clear recovery state: \(error)", category: .library) }
    }
}
