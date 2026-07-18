//
//  LDDCSourceHealthStore.swift
//  myPlayer2
//
//  Tracks slow LDDC providers so batch lyric enrichment can avoid repeating
//  known waits while still allowing an explicit manual retry.
//

import Foundation

/// Controls whether a lyric search should honor the source circuit breaker.
enum LDDCSourceSearchPolicy: Sendable {
    /// Skip a source that recently exceeded the slow-source threshold.
    case adaptive
    /// Probe every requested source, even if it was recently deprioritized.
    case forceAll
}

enum LDDCSourceHealthDecision: Sendable {
    case attempt(startedAt: Date)
    case skip(retryAfter: Date)
}

/// Small in-memory circuit breaker for LDDC providers.
///
/// The state is intentionally process-local. A network interruption should not
/// permanently disable a provider across app launches, while a single batch
/// import can still learn from a slow provider and move on quickly.
actor LDDCSourceHealthStore {

    static let shared = LDDCSourceHealthStore()

    /// A provider that has not answered within this interval is considered
    /// unreliable for subsequent adaptive searches.
    static let slowSourceTimeout: TimeInterval = 15

    private let unreliableCooldown: TimeInterval = 10 * 60

    private struct Entry {
        var timeoutCount: Int
        var unreliableUntil: Date
        var lastEventAt: Date
    }

    private var entries: [LDDCSource: Entry] = [:]

    func decision(
        for source: LDDCSource,
        policy: LDDCSourceSearchPolicy
    ) -> LDDCSourceHealthDecision {
        if case .forceAll = policy {
            return .attempt(startedAt: Date())
        }

        guard let entry = entries[source] else {
            return .attempt(startedAt: Date())
        }

        let now = Date()
        guard entry.unreliableUntil > now else {
            entries[source] = nil
            return .attempt(startedAt: now)
        }

        return .skip(retryAfter: entry.unreliableUntil)
    }

    func recordSuccess(for source: LDDCSource, attemptStartedAt: Date) {
        // A response from an older in-flight request must not clear a newer
        // timeout decision and reopen a source that is still stalled.
        if let entry = entries[source], entry.lastEventAt > attemptStartedAt {
            return
        }
        entries[source] = nil
    }

    func recordTimeout(for source: LDDCSource, attemptStartedAt: Date) {
        if let entry = entries[source], entry.lastEventAt > attemptStartedAt {
            return
        }

        let previousCount = entries[source]?.timeoutCount ?? 0
        let timeoutCount = previousCount + 1
        let cooldownMultiplier = Double(min(timeoutCount, 3))
        let eventTime = Date()
        entries[source] = Entry(
            timeoutCount: timeoutCount,
            unreliableUntil: eventTime.addingTimeInterval(unreliableCooldown * cooldownMultiplier),
            lastEventAt: eventTime
        )
    }
}
