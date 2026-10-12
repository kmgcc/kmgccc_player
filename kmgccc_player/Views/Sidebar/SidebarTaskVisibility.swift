import Foundation

/// When a library task shows in the sidebar's task stack. Only heavy or
/// large-batch work shows there; light work is summarized on the Background
/// Tasks page instead. Each kind registers its own rule, so the sidebar does
/// not list task types itself.
nonisolated enum SidebarTaskVisibility: Equatable, Sendable {
    case always
    /// Shows once the task covers at least this many items.
    case whenAtLeast(Int)
    case never

    /// Batches at or above this size count as large.
    nonisolated static let largeBatchCount = 50
    /// A task shows only after it has been eligible this long, so short tasks
    /// do not flash past.
    nonisolated static let minimumVisibleDelay: TimeInterval = 3

    nonisolated func shows(itemCount: Int?) -> Bool {
        switch self {
        case .always: true
        case .never: false
        case .whenAtLeast(let minimum): (itemCount ?? 0) >= minimum
        }
    }
}

extension LibraryTaskKind {
    nonisolated var sidebarVisibility: SidebarTaskVisibility {
        switch self {
        case .importFiles, .ncmConversion, .libraryBundleExport, .embeddedTagWrite, .loudnessAnalysis:
            .always
        case .automation, .enrichment:
            // Automation-started batches; a handful of songs does not interrupt.
            .whenAtLeast(SidebarTaskVisibility.largeBatchCount)
        case .sourceScan, .indexUpdate, .other:
            // Source scans started by file changes, mounts and activation stay
            // on the Background Tasks page; a rescan the listener asks for is
            // let through by the host.
            .never
        }
    }
}

/// Holds a task back until it has been eligible for the minimum delay.
nonisolated struct SidebarTaskRevealTracker {
    private var eligibleSince: [UUID: TimeInterval] = [:]

    nonisolated init() {}

    /// Returns the tasks that may show now, and how long until the next
    /// waiting task may show.
    nonisolated mutating func update(
        eligible: Set<UUID>,
        now: TimeInterval,
        delay: TimeInterval = SidebarTaskVisibility.minimumVisibleDelay
    ) -> (revealed: Set<UUID>, nextCheck: TimeInterval?) {
        eligibleSince = eligibleSince.filter { eligible.contains($0.key) }
        var revealed = Set<UUID>()
        var nextCheck: TimeInterval?
        for id in eligible {
            let since = eligibleSince[id] ?? now
            eligibleSince[id] = since
            let remaining = since + delay - now
            if remaining <= 0 {
                revealed.insert(id)
            } else {
                nextCheck = min(nextCheck ?? remaining, remaining)
            }
        }
        return (revealed, nextCheck)
    }
}
