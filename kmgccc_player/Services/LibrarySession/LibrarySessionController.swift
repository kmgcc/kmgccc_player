import Foundation

@MainActor
protocol LibrarySessionLifecycle: AnyObject {
    var context: LibraryContext { get }

    func load() async throws
    func flush() async throws
    func quiesce() async
    func close() async
}

@MainActor
protocol LibrarySessionBuilding: AnyObject {
    func makeSession(for context: LibraryContext) async throws -> any LibrarySessionLifecycle
}

nonisolated enum LibrarySessionControllerError: Error, Equatable {
    case superseded
    case targetLoadFailed
    case targetAndRecoveryFailed
}

@MainActor
final class LibrarySessionController {
    enum State: Equatable {
        case idle
        case preparing(UUID)
        case quiescing(UUID)
        case loading(UUID)
        case active(UUID)
        case unavailable(UUID?)
    }

    private let factory: any LibrarySessionBuilding
    private var transactionGeneration: UInt64 = 0
    private var destructiveTransactionGeneration: UInt64?
    private var recoveryContext: LibraryContext?

    private(set) var state: State = .idle
    private(set) var activeSession: (any LibrarySessionLifecycle)?

    var activeLibraryContext: LibraryContext? { activeSession?.context }

    var willReleaseActiveSession: (@MainActor () async -> Void)?
    var didActivateSession: (@MainActor (any LibrarySessionLifecycle) async -> Void)?

    init(factory: any LibrarySessionBuilding) {
        self.factory = factory
    }

    func installInitialSession(_ session: any LibrarySessionLifecycle) {
        transactionGeneration &+= 1
        activeSession = session
        recoveryContext = session.context
        state = .active(session.context.id)
    }

    func switchToLibrary(_ context: LibraryContext) async throws {
        while destructiveTransactionGeneration != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }

        if let activeSession,
           activeSession.context.id == context.id,
           activeSession.context.rootURL == context.rootURL {
            state = .active(activeSession.context.id)
            return
        }

        transactionGeneration &+= 1
        let generation = transactionGeneration
        let previousContext = activeSession?.context ?? recoveryContext
        var ownsDestructivePhase = false
        defer {
            if ownsDestructivePhase,
               destructiveTransactionGeneration == generation {
                destructiveTransactionGeneration = nil
            }
        }

        state = .preparing(context.id)
        let candidate: any LibrarySessionLifecycle
        do {
            candidate = try await factory.makeSession(for: context)
        } catch {
            restoreVisibleStateAfterPreparationFailure(previousContext: previousContext)
            throw error
        }

        guard generation == transactionGeneration else {
            await candidate.close()
            throw LibrarySessionControllerError.superseded
        }

        if let previous = activeSession {
            do {
                try await previous.flush()
            } catch {
                await candidate.close()
                state = .active(previous.context.id)
                throw error
            }

            guard generation == transactionGeneration else {
                await candidate.close()
                state = .active(previous.context.id)
                throw LibrarySessionControllerError.superseded
            }

            destructiveTransactionGeneration = generation
            ownsDestructivePhase = true
            state = .quiescing(context.id)
            await previous.quiesce()

            guard generation == transactionGeneration else {
                await candidate.close()
                throw LibrarySessionControllerError.superseded
            }

            await willReleaseActiveSession?()
            activeSession = nil
            recoveryContext = previous.context
            await previous.close()
        }

        guard generation == transactionGeneration else {
            await candidate.close()
            throw LibrarySessionControllerError.superseded
        }

        state = .loading(context.id)
        do {
            try await candidate.load()
        } catch {
            await candidate.close()
            guard generation == transactionGeneration else {
                throw LibrarySessionControllerError.superseded
            }
            try await recoverPreviousSession(afterTargetFailure: error, generation: generation)
            throw LibrarySessionControllerError.targetLoadFailed
        }

        guard generation == transactionGeneration else {
            await candidate.close()
            throw LibrarySessionControllerError.superseded
        }

        activeSession = candidate
        recoveryContext = context
        await didActivateSession?(candidate)
        state = .active(context.id)
    }

    func closeActiveSession() async throws {
        while destructiveTransactionGeneration != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }

        transactionGeneration &+= 1
        let generation = transactionGeneration
        destructiveTransactionGeneration = generation
        defer {
            if destructiveTransactionGeneration == generation {
                destructiveTransactionGeneration = nil
            }
        }

        guard let activeSession else {
            state = .idle
            recoveryContext = nil
            return
        }

        try await activeSession.flush()
        guard generation == transactionGeneration else { return }

        state = .quiescing(activeSession.context.id)
        await activeSession.quiesce()
        guard generation == transactionGeneration else { return }

        await willReleaseActiveSession?()
        guard generation == transactionGeneration else { return }

        self.activeSession = nil
        recoveryContext = nil
        await activeSession.close()
        guard generation == transactionGeneration else { return }

        state = .idle
    }

    private func recoverPreviousSession(afterTargetFailure: Error, generation: UInt64) async throws {
        guard let recoveryContext else {
            state = .unavailable(nil)
            throw LibrarySessionControllerError.targetAndRecoveryFailed
        }

        do {
            let restored = try await factory.makeSession(for: recoveryContext)
            guard generation == transactionGeneration else {
                await restored.close()
                throw LibrarySessionControllerError.superseded
            }
            try await restored.load()
            guard generation == transactionGeneration else {
                await restored.close()
                throw LibrarySessionControllerError.superseded
            }
            activeSession = restored
            await didActivateSession?(restored)
            state = .active(recoveryContext.id)
        } catch LibrarySessionControllerError.superseded {
            throw LibrarySessionControllerError.superseded
        } catch {
            _ = afterTargetFailure
            activeSession = nil
            state = .unavailable(recoveryContext.id)
            throw LibrarySessionControllerError.targetAndRecoveryFailed
        }
    }

    private func restoreVisibleStateAfterPreparationFailure(previousContext: LibraryContext?) {
        if let activeSession {
            state = .active(activeSession.context.id)
        } else {
            state = .unavailable(previousContext?.id)
        }
    }
}

nonisolated struct PlaybackMemory: Codable, Equatable, Sendable {
    let savedAt: Date
    let trackID: UUID
    let currentTime: Double
    let duration: Double
    var queueTrackIDs: [UUID]?
    var playbackOrderMode: String?
}

nonisolated struct PlaybackMemoryStore {
    static let legacyKey = "playback.memory.v1"
    static let legacyOwnerKey = "playback.memory.v1.migratedLibraryID"
    static let keyPrefix = "playback.memory.v2"
    static let expirationInterval: TimeInterval = 18 * 60 * 60

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func save(_ memory: PlaybackMemory, libraryID: UUID) {
        Self().save(memory, libraryID: libraryID)
    }

    static func loadValid(libraryID: UUID, now: Date = Date()) -> PlaybackMemory? {
        Self().loadValid(libraryID: libraryID, now: now)
    }

    static func clear(libraryID: UUID) {
        Self().clear(libraryID: libraryID)
    }

    func key(for libraryID: UUID) -> String {
        "\(Self.keyPrefix).\(libraryID.uuidString)"
    }

    func save(_ memory: PlaybackMemory, libraryID: UUID) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        defaults.set(data, forKey: key(for: libraryID))
    }

    func loadValid(libraryID: UUID, now: Date = Date()) -> PlaybackMemory? {
        let scopedKey = key(for: libraryID)
        var data = defaults.data(forKey: scopedKey)
        if data == nil,
           defaults.string(forKey: Self.legacyOwnerKey) == nil,
           let legacyData = defaults.data(forKey: Self.legacyKey) {
            data = legacyData
            defaults.set(legacyData, forKey: scopedKey)
            defaults.set(libraryID.uuidString, forKey: Self.legacyOwnerKey)
            defaults.removeObject(forKey: Self.legacyKey)
        }

        guard let data,
              let memory = try? JSONDecoder().decode(PlaybackMemory.self, from: data) else {
            clear(libraryID: libraryID)
            return nil
        }
        guard now.timeIntervalSince(memory.savedAt) <= Self.expirationInterval else {
            clear(libraryID: libraryID)
            return nil
        }
        return memory
    }

    func clear(libraryID: UUID) {
        defaults.removeObject(forKey: key(for: libraryID))
    }

    static func restorableTime(from memory: PlaybackMemory) -> Double {
        guard memory.currentTime.isFinite else { return 0 }
        let lowerBoundedTime = max(0, memory.currentTime)
        guard memory.duration.isFinite, memory.duration > 1 else { return lowerBoundedTime }
        return min(lowerBoundedTime, memory.duration - 1)
    }
}

nonisolated struct FullscreenDeferredReleaseState: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case waitForTransition
        case requestWindowClose
        case complete
    }

    private(set) var didRequestClose = false

    mutating func nextAction(isTransitioning: Bool, hasWindow: Bool) -> Action {
        if isTransitioning { return .waitForTransition }
        guard hasWindow else { return .complete }
        guard !didRequestClose else { return .waitForTransition }
        didRequestClose = true
        return .requestWindowClose
    }
}

nonisolated struct LibraryHostRebuildState: Equatable, Sendable {
    private(set) var releaseGeneration: UInt64 = 0
    private(set) var pendingGeneration: UInt64?

    mutating func recordRelease() -> UInt64 {
        releaseGeneration &+= 1
        pendingGeneration = releaseGeneration
        return releaseGeneration
    }

    mutating func consumeRebuildAfterPublish() -> UInt64? {
        defer { pendingGeneration = nil }
        return pendingGeneration
    }
}

nonisolated struct LegacyLibraryMigrationOwnership: Equatable, Sendable {
    let ownerLibraryID: UUID?

    func canClaim(libraryID: UUID, destinationRoot: URL, upgradedLegacyRoot: URL) -> Bool {
        (ownerLibraryID == nil || ownerLibraryID == libraryID)
            && destinationRoot.standardizedFileURL == upgradedLegacyRoot.standardizedFileURL
    }
}
