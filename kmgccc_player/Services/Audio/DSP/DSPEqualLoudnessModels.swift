import Foundation

/// Output volume of the device that actually plays this App's audio, as read
/// from Core Audio. The App's own volume never contributes to this value.
nonisolated struct OutputDeviceVolumeReading: Codable, Equatable, Sendable {
    nonisolated enum Axis: String, Codable, Equatable, Sendable {
        /// Device attenuation in dB below its maximum output.
        case decibels
        /// Device volume percentage (0...100) when no dB conversion exists.
        case percent
    }

    var deviceUID: String
    var deviceName: String
    /// Device volume slider position, 0...1.
    var scalar: Double
    /// Attenuation below the device's maximum output, always <= 0. Nil when
    /// the device offers no trustworthy scalar-to-dB conversion.
    var decibelsBelowMaximum: Double?
    var isMuted: Bool
    var isWritable: Bool

    nonisolated var axis: Axis { decibelsBelowMaximum == nil ? .percent : .decibels }

    /// Position on the axis a calibration is recorded on.
    nonisolated var coordinate: Double { decibelsBelowMaximum ?? scalar * 100 }

    /// Attenuation used by the default curve. A percentage-only device uses
    /// the common 40·log10 slider law as an approximation; calibration records
    /// percentages directly and never depends on this estimate.
    nonisolated var approximateDecibelsBelowMaximum: Double {
        if let decibelsBelowMaximum { return decibelsBelowMaximum }
        guard scalar > 0 else { return -96 }
        return max(-96, 40 * log10(scalar))
    }
}

nonisolated enum OutputDeviceVolumeState: Codable, Equatable, Sendable {
    case unavailable(deviceUID: String?, deviceName: String?)
    case available(OutputDeviceVolumeReading)

    nonisolated static let unknown = OutputDeviceVolumeState.unavailable(deviceUID: nil, deviceName: nil)

    nonisolated var reading: OutputDeviceVolumeReading? {
        if case .available(let reading) = self { return reading }
        return nil
    }

    nonisolated var deviceUID: String? {
        switch self {
        case .available(let reading): reading.deviceUID
        case .unavailable(let uid, _): uid
        }
    }

    nonisolated var deviceName: String? {
        switch self {
        case .available(let reading): reading.deviceName
        case .unavailable(_, let name): name
        }
    }
}

nonisolated struct EqualLoudnessCalibrationPoint: Codable, Equatable, Sendable {
    /// Volume coordinate on the calibration axis (dB below maximum or percent).
    var coordinate: Double
    var bassDB: Double
    var trebleDB: Double
}

/// One listener's four-step calibration for one output device.
nonisolated struct EqualLoudnessCalibration: Codable, Equatable, Sendable {
    nonisolated static let currentAlgorithmVersion = 1
    nonisolated static let bassRange: ClosedRange<Double> = DSPEqualLoudnessParameters.maxBassGainRange
    nonisolated static let trebleRange: ClosedRange<Double> = DSPEqualLoudnessParameters.maxTrebleGainRange

    var deviceUID: String
    var deviceName: String
    var axis: OutputDeviceVolumeReading.Axis
    /// Recorded from loud to quiet.
    var points: [EqualLoudnessCalibrationPoint]
    var algorithmVersion: Int
    var createdAt: Date

    nonisolated init(
        deviceUID: String,
        deviceName: String,
        axis: OutputDeviceVolumeReading.Axis,
        points: [EqualLoudnessCalibrationPoint],
        algorithmVersion: Int = Self.currentAlgorithmVersion,
        createdAt: Date = Date()
    ) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.axis = axis
        self.points = points
        self.algorithmVersion = algorithmVersion
        self.createdAt = createdAt
    }

    nonisolated var curve: EqualLoudnessCurve? { EqualLoudnessCurve(points: points) }
}

/// Monotone compensation curve through a few calibration points. Pool
/// Adjacent Violators removes inconsistent answers (a quieter step never gets
/// less compensation), then Fritsch–Carlson PCHIP joins the points without
/// overshoot. Outside the recorded span the nearest end value is held.
nonisolated struct EqualLoudnessCurve: Equatable, Sendable {
    private let xs: [Double]
    private let bass: Segments
    private let treble: Segments

    private struct Segments: Equatable, Sendable {
        let ys: [Double]
        let slopes: [Double]
    }

    nonisolated init?(points: [EqualLoudnessCalibrationPoint]) {
        let valid = points.filter {
            $0.coordinate.isFinite && $0.bassDB.isFinite && $0.trebleDB.isFinite
        }
        guard !valid.isEmpty else { return nil }
        // Ascending coordinate means louder; compensation must not increase.
        let sorted = valid.sorted { $0.coordinate < $1.coordinate }
        var uniqueX: [Double] = []
        var bassValues: [Double] = []
        var trebleValues: [Double] = []
        for point in sorted {
            if let last = uniqueX.last, abs(last - point.coordinate) < 1e-9 {
                bassValues[bassValues.count - 1] = (bassValues[bassValues.count - 1] + point.bassDB) / 2
                trebleValues[trebleValues.count - 1] = (trebleValues[trebleValues.count - 1] + point.trebleDB) / 2
            } else {
                uniqueX.append(point.coordinate)
                bassValues.append(point.bassDB)
                trebleValues.append(point.trebleDB)
            }
        }
        xs = uniqueX
        bass = Self.segments(xs: uniqueX, ys: Self.nonIncreasing(bassValues.map {
            min(max($0, EqualLoudnessCalibration.bassRange.lowerBound), EqualLoudnessCalibration.bassRange.upperBound)
        }))
        treble = Self.segments(xs: uniqueX, ys: Self.nonIncreasing(trebleValues.map {
            min(max($0, EqualLoudnessCalibration.trebleRange.lowerBound), EqualLoudnessCalibration.trebleRange.upperBound)
        }))
    }

    nonisolated func gains(at coordinate: Double) -> DSPEqualLoudnessGains {
        guard coordinate.isFinite else { return .zero }
        return DSPEqualLoudnessGains(
            bassDB: Self.evaluate(bass, xs: xs, at: coordinate),
            trebleDB: Self.evaluate(treble, xs: xs, at: coordinate)
        )
    }

    /// Isotonic regression for a non-increasing sequence with equal weights.
    nonisolated static func nonIncreasing(_ values: [Double]) -> [Double] {
        var blocks: [(sum: Double, count: Int)] = []
        for value in values {
            blocks.append((value, 1))
            while blocks.count > 1 {
                let last = blocks[blocks.count - 1]
                let previous = blocks[blocks.count - 2]
                guard previous.sum / Double(previous.count) < last.sum / Double(last.count) else { break }
                blocks.removeLast(2)
                blocks.append((previous.sum + last.sum, previous.count + last.count))
            }
        }
        return blocks.flatMap { Array(repeating: $0.sum / Double($0.count), count: $0.count) }
    }

    private nonisolated static func segments(xs: [Double], ys: [Double]) -> Segments {
        let count = xs.count
        guard count > 1 else { return Segments(ys: ys, slopes: Array(repeating: 0, count: count)) }
        var secants = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            secants[index] = (ys[index + 1] - ys[index]) / (xs[index + 1] - xs[index])
        }
        var slopes = [Double](repeating: 0, count: count)
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                let left = secants[index - 1]
                let right = secants[index]
                if left * right <= 0 {
                    slopes[index] = 0
                } else {
                    let h0 = xs[index] - xs[index - 1]
                    let h1 = xs[index + 1] - xs[index]
                    let w1 = 2 * h1 + h0
                    let w2 = h1 + 2 * h0
                    slopes[index] = (w1 + w2) / (w1 / left + w2 / right)
                }
            }
        }
        // Fritsch–Carlson end and flat-segment constraints keep the curve monotone.
        for index in 0..<(count - 1) where secants[index] == 0 {
            slopes[index] = 0
            slopes[index + 1] = 0
        }
        for index in [0, count - 1] {
            let secant = index == 0 ? secants[0] : secants[count - 2]
            if slopes[index] * secant <= 0 { slopes[index] = 0 }
            if abs(slopes[index]) > 3 * abs(secant) { slopes[index] = 3 * secant }
        }
        return Segments(ys: ys, slopes: slopes)
    }

    private nonisolated static func evaluate(_ segments: Segments, xs: [Double], at x: Double) -> Double {
        guard let first = xs.first, let last = xs.last else { return 0 }
        if x <= first { return segments.ys[0] }
        if x >= last { return segments.ys[xs.count - 1] }
        var upper = 1
        while upper < xs.count - 1, xs[upper] < x { upper += 1 }
        let lower = upper - 1
        let h = xs[upper] - xs[lower]
        let t = (x - xs[lower]) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let value = h00 * segments.ys[lower] + h10 * h * segments.slopes[lower]
            + h01 * segments.ys[upper] + h11 * h * segments.slopes[upper]
        let low = min(segments.ys[lower], segments.ys[upper])
        let high = max(segments.ys[lower], segments.ys[upper])
        return min(max(value, low), high)
    }
}

nonisolated enum EqualLoudnessCalibrationGuide {
    /// macOS volume keys move in sixteenths; each suggested step is one of
    /// those positions so everyday key presses land on calibrated volumes.
    nonisolated static let recommendedScalars: [Double] = [11.0 / 16, 8.0 / 16, 5.0 / 16, 2.0 / 16]
    /// Each step must be at least this much quieter than the previous one.
    nonisolated static let minimumStepDecibels = 4.0
    /// Equivalent spacing for a percentage-only device.
    nonisolated static let minimumStepPercent = 6.0
    nonisolated static let snapCapture = 0.02
    nonisolated static let snapRelease = 0.03

    /// Snapping with hysteresis: a value within ±2 % of a mark takes the mark,
    /// and once held it is only released beyond ±3 %.
    nonisolated static func snapped(_ value: Double, heldMark: Double?) -> (value: Double, mark: Double?) {
        if let heldMark, abs(value - heldMark) <= snapRelease {
            return (heldMark, heldMark)
        }
        if let mark = recommendedScalars.min(by: { abs($0 - value) < abs($1 - value) }),
           abs(mark - value) <= snapCapture {
            return (mark, mark)
        }
        return (value, nil)
    }
}
