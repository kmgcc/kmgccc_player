import Foundation

/// The quiet load of this Mac, learned over the last week. Samples are the 30 s
/// averages of the CPU use of everything except this App, kept as a histogram
/// per day. The baseline is the 25th percentile, so busy stretches such as
/// compiling do not raise it. It stays on this Mac.
nonisolated struct CPUBaselineStore: Codable, Equatable, Sendable {
    nonisolated struct Day: Codable, Equatable, Sendable {
        var day: Int
        var bins: [UInt32]
    }

    nonisolated static let binCount = 101
    nonisolated static let retainedDays = 7
    /// Samples needed before the learned value replaces the default.
    nonisolated static let minimumSamples = 120
    nonisolated static let defaultBaselinePercent = 15.0

    var days: [Day] = []

    nonisolated init() {}

    nonisolated static func dayIndex(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    nonisolated mutating func record(percent: Double, day: Int) {
        let bin = Int(max(0, min(100, percent)).rounded())
        if let index = days.firstIndex(where: { $0.day == day }) {
            days[index].bins[bin] &+= 1
        } else {
            var bins = [UInt32](repeating: 0, count: Self.binCount)
            bins[bin] = 1
            days.append(Day(day: day, bins: bins))
        }
        prune(today: day)
    }

    private nonisolated mutating func prune(today: Int) {
        days.removeAll { today - $0.day >= Self.retainedDays || $0.bins.count != Self.binCount }
    }

    nonisolated func sampleCount(today: Int) -> Int {
        var total = 0
        for day in days where today - day.day < Self.retainedDays {
            for count in day.bins { total += Int(count) }
        }
        return total
    }

    /// The learned baseline, or nil until enough samples exist.
    nonisolated func learnedBaseline(today: Int) -> Double? {
        var merged = [UInt64](repeating: 0, count: Self.binCount)
        for day in days where today - day.day < Self.retainedDays && day.bins.count == Self.binCount {
            for index in 0..<Self.binCount { merged[index] += UInt64(day.bins[index]) }
        }
        let total = merged.reduce(0, +)
        guard total >= UInt64(Self.minimumSamples) else { return nil }
        let target = (Double(total) * 0.25).rounded(.up)
        var cumulative: UInt64 = 0
        for index in 0..<Self.binCount {
            cumulative += merged[index]
            if Double(cumulative) >= target { return Double(index) }
        }
        return nil
    }

    nonisolated func baseline(today: Int) -> Double {
        learnedBaseline(today: today) ?? Self.defaultBaselinePercent
    }
}

/// Decides when the rest of the system is quiet enough for idle batch work,
/// relative to this Mac's own baseline. Start at the lower threshold held for
/// 30 s, pause at the higher one; in between the state is kept.
nonisolated struct IdleCPUGate: Equatable, Sendable {
    nonisolated static let confirmationSeconds: TimeInterval = 30
    nonisolated static let startMargin = 10.0
    nonisolated static let startCeiling = 35.0
    nonisolated static let pauseMargin = 25.0
    nonisolated static let pauseCeiling = 50.0

    private(set) var isOpen = false
    private(set) var lowLoadSince: TimeInterval?
    private(set) var hasSample = false

    nonisolated init() {}

    nonisolated static func startThreshold(baseline: Double) -> Double {
        min(baseline + startMargin, startCeiling)
    }

    nonisolated static func pauseThreshold(baseline: Double) -> Double {
        min(baseline + pauseMargin, pauseCeiling)
    }

    /// Feeds the latest 30 s average of the load excluding this App.
    nonisolated mutating func ingest(average: Double, baseline: Double, now: TimeInterval) {
        hasSample = true
        if isOpen {
            if average >= Self.pauseThreshold(baseline: baseline) {
                isOpen = false
                lowLoadSince = nil
            }
            return
        }
        if average <= Self.startThreshold(baseline: baseline) {
            if let since = lowLoadSince {
                if now - since >= Self.confirmationSeconds { isOpen = true }
            } else {
                lowLoadSince = now
            }
        } else {
            lowLoadSince = nil
        }
    }

    /// Forgets the state when sampling stops; the next idle period starts over.
    nonisolated mutating func reset() {
        isOpen = false
        lowLoadSince = nil
        hasSample = false
    }

    nonisolated var waitReason: BackgroundWaitReason? {
        if isOpen { return nil }
        return !hasSample || lowLoadSince != nil ? .confirmingIdle : .systemBusy
    }
}
