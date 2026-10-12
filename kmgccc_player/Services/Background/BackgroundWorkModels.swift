import Foundation

/// Order in which deferrable work is admitted. Real-time work (audio supply,
/// what the listener is looking at) never goes through the scheduler.
nonisolated enum BackgroundWorkPriority: Int, Comparable, Codable, Sendable, CaseIterable {
    /// Started by the listener, such as analyzing the current song.
    case userRequested = 0
    /// Needed soon, such as the next songs in the queue.
    case upcoming = 1
    /// Library-wide preparation that only uses spare capacity.
    case idleBatch = 2

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Quality of service the unit runs at. Idle work runs at background
    /// priority, which Apple Silicon places on the efficiency cores and whose
    /// disk access the system throttles.
    nonisolated var taskPriority: TaskPriority {
        switch self {
        case .userRequested: .userInitiated
        case .upcoming: .utility
        case .idleBatch: .background
        }
    }
}

/// Resource channels a unit occupies. Each channel has its own concurrency
/// budget, so a network task never waits behind a computation.
nonisolated enum BackgroundWorkChannel: Int, CaseIterable, Sendable {
    case compute
    case disk
    case network
}

nonisolated struct BackgroundWorkResources: OptionSet, Sendable, Hashable {
    let rawValue: Int
    nonisolated static let compute = BackgroundWorkResources(rawValue: 1 << 0)
    nonisolated static let disk = BackgroundWorkResources(rawValue: 1 << 1)
    nonisolated static let network = BackgroundWorkResources(rawValue: 1 << 2)

    nonisolated func uses(_ channel: BackgroundWorkChannel) -> Bool {
        switch channel {
        case .compute: contains(.compute)
        case .disk: contains(.disk)
        case .network: contains(.network)
        }
    }

    /// Computation and disk share one idle slot: at any moment the App runs
    /// at most one idle unit that does heavy work.
    nonisolated var usesHeavyChannels: Bool { !isDisjoint(with: [.compute, .disk]) }
}

/// Who a unit belongs to. A library owner carries the session generation, so
/// work of a closed library session can never continue inside the next one.
nonisolated enum BackgroundWorkOwner: Hashable, Sendable {
    case app
    case library(id: UUID, generation: UInt64)

    nonisolated var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

/// What a scheduled domain does, for grouping, cards and statistics.
nonisolated enum BackgroundWorkDomain: String, CaseIterable, Sendable {
    case loudness
    case artworkColors
    case cacheMaintenance
    /// Larger cover and colour warm-up for the playing song and its neighbours.
    case playbackArtwork
    /// The next song's lyric file, read before the song starts.
    case nextSongLyrics
    /// Home page cover warm-up.
    case homeArtwork
    /// Page thumbnails for the albums and artists the Home page shows, made in
    /// idle time and kept in the derivative cache.
    case pageThumbnails
    /// Cover prefetch around the list the listener is browsing.
    case listArtwork
    /// Generated playlist and artist covers that are still missing.
    case missingArtwork
    /// The lyrics database index kept fresh for lyric search.
    case lyricsIndex
    /// Staging leftovers, retired caches and index repair after a reload.
    case libraryMaintenance
    /// Downloading a found App update before the listener asks for it.
    case appUpdate
    /// Looking up song information and covers online, after an import or on
    /// the listener's request.
    case importEnrichment
    /// Keeping the library in step with its folders.
    case sourceSync
    /// Writing tags into audio files, and other file work the listener asked for.
    case fileWork

    /// Image preparation pauses under serious heat and briefly after a new
    /// memory pressure event, even when it is needed soon.
    nonisolated var isVisualPreparation: Bool {
        switch self {
        case .artworkColors, .playbackArtwork, .homeArtwork, .listArtwork, .missingArtwork,
             .pageThumbnails: true
        case .loudness, .cacheMaintenance, .lyricsIndex, .libraryMaintenance, .appUpdate,
             .importEnrichment, .sourceSync, .fileWork, .nextSongLyrics: false
        }
    }

    /// Needed for a user-visible feature to work at all, so the "prepare in
    /// idle time" switch does not stop its upcoming work. Volume
    /// normalization measures the current and next songs regardless, an App
    /// update that waited a day is downloaded even with the switch off, and
    /// the library keeps following its folders.
    nonisolated var survivesPreparationSwitch: Bool {
        self == .loudness || self == .appUpdate || self == .sourceSync
    }

    /// Single tasks whose last completion the Background Tasks page reports
    /// ("tidied at 10:24"), so it is kept across launches.
    nonisolated var persistsLastCompletion: Bool {
        switch self {
        case .cacheMaintenance, .libraryMaintenance, .lyricsIndex, .appUpdate: true
        default: false
        }
    }
}

/// What the scheduler holds for one domain, for surfaces that summarize it.
nonisolated struct BackgroundDomainActivity: Equatable, Sendable {
    var running = 0
    var paused = 0
    var waiting = 0

    nonisolated init() {}

    nonisolated var isIdle: Bool { running == 0 && paused == 0 && waiting == 0 }
}

nonisolated enum BackgroundWorkOutcome: Equatable, Sendable {
    case completed
    case failed(String)
    case cancelled
}

nonisolated struct BackgroundWorkProgress: Equatable, Sendable {
    var completed: Int = 0
    var failed: Int = 0
    var remaining: Int = 0

    nonisolated static let empty = BackgroundWorkProgress()
}

/// One piece of work, small enough to finish in a second or two or to
/// checkpoint inside. The closure runs off the main actor at the unit's
/// quality of service.
nonisolated struct BackgroundWorkUnit: Sendable {
    let id: String
    let priority: BackgroundWorkPriority
    /// Host of the network request, used to cap concurrent requests per host.
    var networkHost: String?
    let run: @Sendable (BackgroundWorkContext) async -> BackgroundWorkOutcome

    nonisolated init(
        id: String,
        priority: BackgroundWorkPriority,
        networkHost: String? = nil,
        run: @escaping @Sendable (BackgroundWorkContext) async -> BackgroundWorkOutcome
    ) {
        self.id = id
        self.priority = priority
        self.networkHost = networkHost
        self.run = run
    }
}

/// A domain's backlog, pulled by the scheduler when a channel has room. The
/// remaining work is derived from the domain's own state, so new items and
/// changed order show up on the next pull and nothing is persisted.
@MainActor
protocol BackgroundWorkSource: AnyObject {
    var sourceID: String { get }
    var domain: BackgroundWorkDomain { get }
    var owner: BackgroundWorkOwner { get }
    var resources: BackgroundWorkResources { get }
    /// Counts for cards and progress notices.
    var progress: BackgroundWorkProgress { get }
    /// Whether a unit at exactly `priority` could be handed out now.
    func hasWork(priority: BackgroundWorkPriority, excluding: Set<String>) -> Bool
    /// The most urgent unit at exactly `priority`, skipping `excluding`, which
    /// holds the units currently running, paused or recently failed.
    func nextUnit(priority: BackgroundWorkPriority, excluding: Set<String>) -> BackgroundWorkUnit?
    /// A handed-out unit ended. A cancelled unit stays in the backlog when the
    /// domain still derives it as outstanding.
    func unitDidEnd(unitID: String, outcome: BackgroundWorkOutcome)
}

extension BackgroundWorkSource {
    func unitDidEnd(unitID: String, outcome: BackgroundWorkOutcome) {}
}

/// Why background work is not running right now.
nonisolated enum BackgroundWaitReason: String, CaseIterable, Equatable, Sendable {
    case disabled
    case launching
    case onBattery
    case lowPowerMode
    case thermal
    case memoryPressure
    case systemBusy
    case confirmingIdle
    case libraryBusy
    case importing
    case userActive
    case playbackSupply
    case resting
    case offline
    case expensiveNetwork

    nonisolated var message: String {
        switch self {
        case .disabled: "已暂停"
        case .launching: "启动完成后开始"
        case .onBattery: "等待接通电源"
        case .lowPowerMode: "低电量模式下暂停"
        case .thermal: "设备温度较高，稍后继续"
        case .memoryPressure: "内存紧张，稍后继续"
        case .systemBusy: "系统负载较高，稍后继续"
        case .confirmingIdle: "等待空闲"
        case .libraryBusy: "资料库正在更新"
        case .importing: "正在导入歌曲"
        case .userActive: "正在使用，稍后继续"
        case .playbackSupply: "播放优先，稍后继续"
        case .resting: "稍作休息"
        case .offline: "等待联网"
        case .expensiveNetwork: "当前为计费网络，稍后继续"
        }
    }
}

/// Declarations of the real-time and write layers that ask background work to
/// step aside. A hold ends when its owner releases or drops it.
nonisolated enum BackgroundHoldKind: String, CaseIterable, Sendable {
    case libraryWrite
    case importing
    case fullscreen
}

/// Counts live holds. Releasing from any thread is safe; the scheduler is
/// told on the main actor.
nonisolated final class BackgroundHoldRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [BackgroundHoldKind: Int] = [:]
    private var onChange: (@Sendable () -> Void)?

    nonisolated init() {}

    nonisolated func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onChange = handler }
    }

    nonisolated func acquire(_ kind: BackgroundHoldKind) {
        lock.withLock { counts[kind, default: 0] += 1 }
        notify()
    }

    nonisolated func release(_ kind: BackgroundHoldKind) {
        lock.withLock {
            if let count = counts[kind], count > 1 {
                counts[kind] = count - 1
            } else {
                counts[kind] = nil
            }
        }
        notify()
    }

    nonisolated func isHeld(_ kind: BackgroundHoldKind) -> Bool {
        lock.withLock { (counts[kind] ?? 0) > 0 }
    }

    private nonisolated func notify() {
        let handler = lock.withLock { onChange }
        handler?()
    }
}

nonisolated final class BackgroundWorkHold: @unchecked Sendable {
    nonisolated let kind: BackgroundHoldKind
    private let registry: BackgroundHoldRegistry
    private let lock = NSLock()
    private var released = false

    nonisolated init(kind: BackgroundHoldKind, registry: BackgroundHoldRegistry) {
        self.kind = kind
        self.registry = registry
        registry.acquire(kind)
    }

    nonisolated func release() {
        let shouldRelease = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if shouldRelease { registry.release(kind) }
    }

    deinit { release() }
}

/// Handle of a submitted single task. Resubmitting the same key returns the
/// same handle.
@MainActor
final class BackgroundTaskHandle {
    let key: String
    private(set) var outcome: BackgroundWorkOutcome?
    private var continuations: [CheckedContinuation<BackgroundWorkOutcome, Never>] = []
    fileprivate weak var scheduler: BackgroundWorkScheduler?

    init(key: String, scheduler: BackgroundWorkScheduler) {
        self.key = key
        self.scheduler = scheduler
    }

    /// Waits for the task to end.
    func value() async -> BackgroundWorkOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuations.append($0) }
    }

    func cancel() { scheduler?.cancel(taskKey: key) }

    func fulfill(_ result: BackgroundWorkOutcome) {
        guard outcome == nil else { return }
        outcome = result
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: result) }
    }
}
