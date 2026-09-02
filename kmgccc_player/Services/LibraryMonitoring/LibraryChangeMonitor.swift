import CoreServices
import Foundation

nonisolated enum ReferencedSourceScanState: Sendable, Equatable {
    case idle
    case scanning
    case failed
}

nonisolated struct LibraryFileEvent: Sendable, Equatable {
    var path: String
    var requiresFullScan: Bool
}

nonisolated struct ManagedLibraryFileEventFilter: Sendable {
    private let rootPath: String
    private let authoritativeDirectoryNames = Set(["Tracks", "Playlists", "Artists", "Albums"])

    init(paths: LibraryPaths) {
        rootPath = paths.rootURL.standardizedFileURL.path
    }

    func shouldProcess(_ event: LibraryFileEvent) -> Bool {
        let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }

        let relativePath = String(path.dropFirst(rootPath.count + 1))
        guard let firstComponent = relativePath.split(separator: "/", omittingEmptySubsequences: true).first,
              authoritativeDirectoryNames.contains(String(firstComponent))
        else {
            return false
        }

        let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return !fileName.hasSuffix(".sqlite")
            && !fileName.hasSuffix(".sqlite-wal")
            && !fileName.hasSuffix(".sqlite-shm")
    }
}

nonisolated protocol LibraryFileEventSource: AnyObject, Sendable {
    func start(paths: [String], handler: @escaping @Sendable ([LibraryFileEvent]) -> Void) throws
    func stop()
}

nonisolated final class FSEventsLibraryFileEventSource: LibraryFileEventSource, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.kmgccc.player.library-fsevents", qos: .utility)

    func start(paths: [String], handler: @escaping @Sendable ([LibraryFileEvent]) -> Void) throws {
        try queue.sync {
            releaseStream()
            guard !paths.isEmpty else { return }
            let box = CallbackBox(handler: handler)
            let info = Unmanaged.passRetained(box).toOpaque()
            var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: { pointer in
                guard let pointer else { return }
                Unmanaged<CallbackBox>.fromOpaque(pointer).release()
            }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, clientInfo, count, eventPaths, flags, _ in
                guard let clientInfo else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(clientInfo).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                var events: [LibraryFileEvent] = []
                events.reserveCapacity(count)
                for index in 0..<min(count, paths.count) {
                    let flag = flags[index]
                    let fullMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
                    events.append(.init(path: paths[index], requiresFullScan: flag & fullMask != 0))
                }
                box.handler(events)
            }
            guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)) else {
                Unmanaged<CallbackBox>.fromOpaque(info).release()
                throw CocoaError(.fileReadUnknown)
            }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                releaseStream()
                throw CocoaError(.fileReadUnknown)
            }
        }
    }

    func stop() {
        queue.sync { releaseStream() }
    }

    /// Must only be called from `queue.sync` context.
    private func releaseStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

nonisolated private final class CallbackBox: @unchecked Sendable {
    let handler: @Sendable ([LibraryFileEvent]) -> Void
    init(handler: @escaping @Sendable ([LibraryFileEvent]) -> Void) { self.handler = handler }
}

actor LibraryChangeMonitor {
    typealias ScanHandler = @Sendable (Set<UUID>, Bool) async -> Void
    typealias EventFilter = @Sendable (LibraryFileEvent) -> Bool

    private let eventSource: LibraryFileEventSource
    private let debounceNanoseconds: UInt64
    private var sourcePaths: [UUID: String] = [:]
    private var dirtySourceIDs = Set<UUID>()
    private var forceFullScan = false
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var handler: ScanHandler?
    private var eventFilter: EventFilter?
    private var stopped = true
    private var sourceStates: [UUID: ReferencedSourceScanState] = [:]
    /// Push hook for UI consumers: fired on every scan-state transition so
    /// views can observe a published snapshot instead of polling. The receiver
    /// is responsible for hopping to the MainActor.
    private var scanStateChangeHandler: (@Sendable ([UUID: ReferencedSourceScanState]) -> Void)?

    init(eventSource: LibraryFileEventSource = FSEventsLibraryFileEventSource(), debounceNanoseconds: UInt64 = 750_000_000) {
        self.eventSource = eventSource
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// Installs (or clears) the callback invoked whenever `sourceStates`
    /// transitions. Fires immediately with the current snapshot so a freshly
    /// bound consumer starts consistent.
    func setScanStateChangeHandler(_ handler: (@Sendable ([UUID: ReferencedSourceScanState]) -> Void)?) {
        scanStateChangeHandler = handler
        notifyScanStateChange()
    }

    private func notifyScanStateChange() {
        guard let scanStateChangeHandler else { return }
        scanStateChangeHandler(sourceStates)
    }

    func start(
        sourceRoots: [UUID: URL],
        eventFilter: @escaping EventFilter = { _ in true },
        initiallyDirty: Bool = true,
        handler: @escaping ScanHandler
    ) async throws {
        await stopAndWait()
        sourcePaths = sourceRoots.mapValues { $0.standardizedFileURL.path }
        sourceStates = sourceRoots.mapValues { _ in .idle }
        notifyScanStateChange()
        self.handler = handler
        self.eventFilter = eventFilter
        stopped = false
        do {
            try eventSource.start(paths: Array(sourcePaths.values)) { [weak self] events in
                Task { await self?.receive(events) }
            }
        } catch {
            stopImmediately()
            throw error
        }
        if initiallyDirty {
            dirtySourceIDs = Set(sourceRoots.keys)
            scheduleDebounce()
        }
    }

    func removeSource(_ sourceID: UUID) throws {
        guard !stopped else { return }
        sourcePaths.removeValue(forKey: sourceID)
        dirtySourceIDs.remove(sourceID)
        let currentHandler = handler
        eventSource.stop()
        try eventSource.start(paths: Array(sourcePaths.values)) { [weak self] events in
            Task { await self?.receive(events) }
        }
        handler = currentHandler
    }

    func sourceStateSnapshot() -> [UUID: ReferencedSourceScanState] { sourceStates }

    func markDirty(sourceIDs: Set<UUID>, fullScan: Bool = false) {
        guard !stopped else { return }
        dirtySourceIDs.formUnion(sourceIDs)
        forceFullScan = forceFullScan || fullScan
        scheduleDebounce()
    }

    func stopAndWait() async {
        stopped = true
        eventSource.stop()
        debounceTask?.cancel()
        debounceTask = nil
        scanTask?.cancel()
        await scanTask?.value
        scanTask = nil
        sourcePaths.removeAll()
        dirtySourceIDs.removeAll()
        sourceStates.removeAll()
        handler = nil
        eventFilter = nil
    }

    private func stopImmediately() {
        stopped = true
        eventSource.stop()
        debounceTask?.cancel()
        scanTask?.cancel()
        debounceTask = nil
        scanTask = nil
        sourcePaths.removeAll()
        dirtySourceIDs.removeAll()
        sourceStates.removeAll()
        handler = nil
        eventFilter = nil
    }

    private func receive(_ events: [LibraryFileEvent]) {
        guard !stopped else { return }
        for event in events {
            if event.requiresFullScan {
                dirtySourceIDs.formUnion(sourcePaths.keys)
                forceFullScan = true
                continue
            }
            guard eventFilter?(event) ?? true else { continue }
            for (sourceID, root) in sourcePaths where event.path == root || event.path.hasPrefix(root + "/") {
                dirtySourceIDs.insert(sourceID)
            }
        }
        if !dirtySourceIDs.isEmpty {
            scheduleDebounce()
        }
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() {
        guard !stopped, scanTask == nil, let handler, !dirtySourceIDs.isEmpty else { return }
        let ids = dirtySourceIDs
        let full = forceFullScan
        dirtySourceIDs.removeAll()
        forceFullScan = false
        for id in ids { sourceStates[id] = .scanning }
        notifyScanStateChange()
        scanTask = Task { [weak self] in
            await handler(ids, full)
            await self?.scanFinished(ids: ids)
        }
    }

    func markFailed(sourceIDs: Set<UUID>) {
        for id in sourceIDs { sourceStates[id] = .failed }
        notifyScanStateChange()
    }

    private func scanFinished(ids: Set<UUID>) {
        for id in ids where sourceStates[id] == .scanning { sourceStates[id] = .idle }
        notifyScanStateChange()
        scanTask = nil
        guard !stopped, !dirtySourceIDs.isEmpty else { return }
        scheduleDebounce()
    }
}
