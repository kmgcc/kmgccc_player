//
//  ProcessFileDescriptorBudget.swift
//  myPlayer2
//
//  Raises the per-process file-descriptor soft limit to the hard limit.
//

import Darwin
import Foundation

nonisolated enum ProcessFileDescriptorBudget {
    /// `RLIM_INFINITY` from `<sys/resource.h>`. The macro is not imported into
    /// Swift, and macOS defines it as `(1 << 63) - 1` rather than `rlim_t.max`.
    private static let unlimited: rlim_t = (rlim_t(1) << 63) - 1

    /// macOS starts GUI apps with a 256-descriptor soft limit while the hard
    /// limit is unlimited. A library session holds artwork caches, SQLite
    /// stores, scopes for referenced sources and the framework's own
    /// descriptors, so 256 is reached long before the library is usable.
    /// Exhaustion surfaces as "Too many open files" in whichever subsystem
    /// happens to allocate next, including the registry commit that completes
    /// library activation.
    static func raiseToHardLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let hardLimit = limit.rlim_max
        guard limit.rlim_cur < hardLimit else {
            // Already raised (a child process inherits the limit). Logged so a
            // later FD investigation can tell the cap from the usage.
            let current = limit.rlim_cur == unlimited ? "unlimited" : String(limit.rlim_cur)
            Log.info("[Lifecycle] file descriptor limit already \(current)", category: .library)
            return
        }
        var updated = limit
        updated.rlim_cur = hardLimit
        guard setrlimit(RLIMIT_NOFILE, &updated) == 0 else {
            Log.warning("[Lifecycle] failed to raise file descriptor limit", category: .library)
            return
        }
        let description = hardLimit == unlimited ? "unlimited" : String(hardLimit)
        Log.info("[Lifecycle] file descriptor limit raised to \(description)", category: .library)
    }
}
