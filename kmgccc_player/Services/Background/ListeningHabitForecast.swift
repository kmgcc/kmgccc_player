import Foundation

/// Learns, on this Mac only, at which hours of the week listening usually
/// starts. Background preparation uses it to order work, so songs that are
/// likely to be played soon are prepared first. It never relaxes the
/// scheduler's live conditions and never outranks a listener's request.
@MainActor
final class ListeningHabitForecast {
    private static let storageKey = "background.listening-habit.v1"
    private static let hoursPerWeek = 168
    /// Older habits fade so a changed routine takes over within weeks.
    private static let decayPerRecord = 0.995

    private var weights: [Double]
    private let defaults: UserDefaults
    private var lastRecordedHour: Int?

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        let stored = userDefaults.array(forKey: Self.storageKey) as? [Double]
        weights = stored?.count == Self.hoursPerWeek ? stored! : Array(repeating: 0, count: Self.hoursPerWeek)
    }

    /// Records that listening started now. Repeated starts within the same
    /// hour count once.
    func recordListeningStart(at date: Date = Date()) {
        let hour = Self.hourOfWeek(date)
        guard hour != lastRecordedHour else { return }
        lastRecordedHour = hour
        for index in weights.indices { weights[index] *= Self.decayPerRecord }
        weights[hour] += 1
        defaults.set(weights, forKey: Self.storageKey)
    }

    /// Share of past listening starts that fell in the coming `hours`.
    func listeningLikelihood(withinHours hours: Int = 1, from date: Date = Date()) -> Double {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        let start = Self.hourOfWeek(date)
        let upcoming = (0...max(0, hours)).reduce(0.0) { sum, offset in
            sum + weights[(start + offset) % Self.hoursPerWeek]
        }
        return upcoming / total
    }

    /// True when the coming hour usually brings listening, so preparation
    /// should favor songs that are likely to be played.
    func expectsListeningSoon(from date: Date = Date()) -> Bool {
        // A uniform habit spreads about 1.2 % over two hourly slots; three
        // times that marks a clearly preferred listening time.
        listeningLikelihood(withinHours: 1, from: date) > 3.0 * 2 / Double(Self.hoursPerWeek)
    }

    private static func hourOfWeek(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.weekday, .hour], from: date)
        let weekday = (components.weekday ?? 1) - 1
        return weekday * 24 + (components.hour ?? 0)
    }
}
