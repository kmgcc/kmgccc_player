import CoreServices
import Foundation

nonisolated struct LibraryFileEvent: Sendable, Equatable {
    var path: String
    var requiresFullScan: Bool
}

nonisolated protocol LibraryFileEventSource: AnyObject, Sendable {
    func start(paths: [String], handler: @escaping @Sendable ([LibraryFileEvent]) -> Void) throws
    func stop()
}

nonisolated final class FSEventsLibraryFileEventSource: LibraryFileEventSource, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.kmgccc.player.library-fsevents", qos: .utility)

    func start(paths: [String], handler: @escaping @Sendable ([LibraryFileEvent]) -> Void) throws {
        stop()
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
            stop()
            throw CocoaError(.fileReadUnknown)
        }
    }

    func stop() {
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

    private let eventSource: LibraryFileEventSource
    private let debounceNanoseconds: UInt64
    private var sourcePaths: [UUID: String] = [:]
    private var dirtySourceIDs = Set<UUID>()
    private var forceFullScan = false
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var handler: ScanHandler?
    private var stopped = true

    init(eventSource: LibraryFileEventSource = FSEventsLibraryFileEventSource(), debounceNanoseconds: UInt64 = 750_000_000) {
        self.eventSource = eventSource
        self.debounceNanoseconds = debounceNanoseconds
    }

    func start(sourceRoots: [UUID: URL], handler: @escaping ScanHandler) async throws {
        await stopAndWait()
        sourcePaths = sourceRoots.mapValues { $0.standardizedFileURL.path }
        self.handler = handler
        stopped = false
        do {
            try eventSource.start(paths: Array(sourcePaths.values)) { [weak self] events in
                Task { await self?.receive(events) }
            }
        } catch {
            stopImmediately()
            throw error
        }
        dirtySourceIDs = Set(sourceRoots.keys)
        scheduleDebounce()
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
        handler = nil
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
        handler = nil
    }

    private func receive(_ events: [LibraryFileEvent]) {
        guard !stopped else { return }
        for event in events {
            for (sourceID, root) in sourcePaths where event.path == root || event.path.hasPrefix(root + "/") {
                dirtySourceIDs.insert(sourceID)
            }
            forceFullScan = forceFullScan || event.requiresFullScan
        }
        scheduleDebounce()
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
        scanTask = Task { [weak self] in
            await handler(ids, full)
            await self?.scanFinished()
        }
    }

    private func scanFinished() {
        scanTask = nil
        guard !stopped, !dirtySourceIDs.isEmpty else { return }
        scheduleDebounce()
    }
}
