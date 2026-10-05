import Foundation
import Observation

/// Host-local identity and asynchronous work. Playback and lyrics keep their existing owners.
@Observable
@MainActor
final class SkinSession {
    private(set) var generation: UInt64 = 0
    @ObservationIgnored private var activeSkinID: String?
    @ObservationIgnored private var activeRevision: UInt64 = 0
    @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cleanups: [UUID: @MainActor () -> Void] = [:]

    func activate(_ skinID: String, revision: UInt64 = 0) {
        guard activeSkinID != skinID || activeRevision != revision else { return }
        if activeSkinID != nil {
            cancelWork()
            generation &+= 1
        }
        activeSkinID = skinID
        activeRevision = revision
    }

    func deactivate() {
        cancelWork()
        activeSkinID = nil
        generation &+= 1
    }

    func identity(for skinID: String) -> String {
        "\(skinID)_\(generation)"
    }

    func perform(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        work[id] = Task { [weak self] in
            await operation()
            self?.work.removeValue(forKey: id)
        }
    }

    /// Register instance-owned subscriptions or rendering resources. Shared services
    /// retain their owner; the cleanup only releases this scene's lease.
    @discardableResult
    func registerCleanup(_ cleanup: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        cleanups[id] = cleanup
        return id
    }

    func removeCleanup(_ id: UUID) { cleanups.removeValue(forKey: id) }

    private func cancelWork() {
        work.values.forEach { $0.cancel() }
        work.removeAll()
        let retiring = Array(cleanups.values)
        cleanups.removeAll()
        retiring.forEach { $0() }
    }
}
