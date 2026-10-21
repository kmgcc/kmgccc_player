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

    /// Position on the reading's native axis.
    nonisolated var coordinate: Double { coordinate(on: axis) }

    /// Position on a fixed calibration axis. Device dB readings can be
    /// temporarily unavailable; keep the calibration comparable by using the
    /// documented slider-law estimate rather than switching units mid-guide.
    nonisolated func coordinate(on axis: Axis) -> Double {
        switch axis {
        case .decibels:
            decibelsBelowMaximum ?? approximateDecibelsBelowMaximum
        case .percent:
            scalar * 100
        }
    }

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

/// One listener's four-step calibration for one output route. The reference
/// step is 0 dB by definition; quieter steps usually boost, louder steps may cut.
nonisolated struct EqualLoudnessCalibration: Codable, Equatable, Sendable {
    nonisolated static let currentAlgorithmVersion = 1
    nonisolated static let bassRange: ClosedRange<Double> = DSPEqualLoudnessParameters.bassGainRange
    nonisolated static let trebleRange: ClosedRange<Double> = DSPEqualLoudnessParameters.trebleGainRange

    /// The route it was recorded on (`DSPOutputDeviceKey.rawValue`).
    var deviceKey: String
    var deviceName: String
    var axis: OutputDeviceVolumeReading.Axis
    /// In the order they were recorded: reference, quieter, quieter, louder.
    var points: [EqualLoudnessCalibrationPoint]
    var algorithmVersion: Int
    var createdAt: Date

    nonisolated init(
        deviceKey: String,
        deviceName: String,
        axis: OutputDeviceVolumeReading.Axis,
        points: [EqualLoudnessCalibrationPoint],
        algorithmVersion: Int = Self.currentAlgorithmVersion,
        createdAt: Date = Date()
    ) {
        self.deviceKey = deviceKey
        self.deviceName = deviceName
        self.axis = axis
        self.points = points
        self.algorithmVersion = algorithmVersion
        // Match the Unix-seconds wire precision at creation. Converting a
        // finer Date only when saving can change equality after a reload.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970)
    }

    nonisolated var curve: EqualLoudnessCurve? { EqualLoudnessCurve(points: points) }

    /// Presets, the working draft and automation use different date
    /// strategies; the wire form keeps `createdAt` as Unix seconds for all.
    nonisolated init(from decoder: Decoder) throws {
        let json = try DSPJSONValue(from: decoder)
        guard let calibration = Self(json: json) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unreadable equal-loudness calibration."
            ))
        }
        self = calibration
    }

    nonisolated func encode(to encoder: Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    nonisolated var jsonValue: DSPJSONValue {
        .object([
            "deviceKey": .string(deviceKey),
            "deviceName": .string(deviceName),
            "axis": .string(axis.rawValue),
            "points": .array(points.map {
                .object([
                    "coordinate": .number($0.coordinate),
                    "bassDB": .number($0.bassDB),
                    "trebleDB": .number($0.trebleDB),
                ])
            }),
            "algorithmVersion": .integer(Int64(algorithmVersion)),
            "createdAt": .number(createdAt.timeIntervalSince1970),
        ])
    }

    nonisolated init?(json: DSPJSONValue) {
        guard case .object(let fields) = json,
              case .string(let deviceKey)? = fields["deviceKey"],
              case .string(let rawAxis)? = fields["axis"],
              let axis = OutputDeviceVolumeReading.Axis(rawValue: rawAxis),
              case .array(let rawPoints)? = fields["points"],
              let version = fields["algorithmVersion"]?.numberValue else { return nil }
        var points: [EqualLoudnessCalibrationPoint] = []
        for rawPoint in rawPoints {
            guard case .object(let point) = rawPoint,
                  let coordinate = point["coordinate"]?.numberValue,
                  let bassDB = point["bassDB"]?.numberValue,
                  let trebleDB = point["trebleDB"]?.numberValue else { return nil }
            points.append(EqualLoudnessCalibrationPoint(coordinate: coordinate, bassDB: bassDB, trebleDB: trebleDB))
        }
        var deviceName = deviceKey
        if case .string(let name)? = fields["deviceName"] { deviceName = name }
        self.init(
            deviceKey: deviceKey,
            deviceName: deviceName,
            axis: axis,
            points: points,
            algorithmVersion: Int(version),
            createdAt: Date(timeIntervalSince1970: fields["createdAt"]?.numberValue ?? 0)
        )
    }
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
        // End slopes ease into horizontal plateaus with C1 continuity, eliminating corner kinks.
        slopes[0] = 0
        slopes[count - 1] = 0
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
        // Fritsch–Carlson flat-segment and overshoot constraints keep the curve monotone.
        for index in 0..<(count - 1) {
            let secant = secants[index]
            if abs(secant) < 1e-12 {
                slopes[index] = 0
                slopes[index + 1] = 0
                continue
            }
            let alpha = slopes[index] / secant
            let beta = slopes[index + 1] / secant
            if alpha < 0 { slopes[index] = 0 }
            if beta < 0 { slopes[index + 1] = 0 }
            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let tau = 3.0 / sqrt(magnitude)
                slopes[index] = tau * alpha * secant
                slopes[index + 1] = tau * beta * secant
            }
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

/// The calibration starts at a moderate reference volume, then moves quieter
/// twice and louder once. Suggested volumes sit on the sixteenths the macOS
/// volume keys step through, so everyday key presses land on calibrated
/// points; they shift away from the recorded volumes when the listener moved
/// the reference.
nonisolated enum EqualLoudnessCalibrationGuide {
    nonisolated enum Direction: Equatable, Sendable {
        case reference
        case quieter
        case louder
    }

    nonisolated static let stepCount = 4
    nonisolated static let directions: [Direction] = [.reference, .quieter, .quieter, .louder]
    nonisolated static let suggestedScalars: [Double] = [5.0 / 16, 3.0 / 16, 2.0 / 16, 8.0 / 16]
    nonisolated static let volumeStep = 1.0 / 16
    nonisolated static let lowestSuggestedScalar = 1.0 / 16
    nonisolated static let highestSuggestedScalar = 12.0 / 16
    /// Each step must lie at least this far beyond every recorded volume.
    nonisolated static let minimumStepDecibels = 3.0
    /// Equivalent spacing for a percentage-only device.
    nonisolated static let minimumStepPercent = 5.0
    nonisolated static let snapCapture = 0.02
    nonisolated static let snapRelease = 0.03

    /// Smooth in log volume so the quiet-to-loud step does not front-load
    /// most of the perceived increase. Exact endpoints include silence.
    nonisolated static func rampScalar(from start: Double, to target: Double, progress: Double) -> Double {
        let t = min(1, max(0, progress))
        if t == 0 { return start }
        if t == 1 { return target }
        let eased = t * t * (3 - 2 * t)
        let floor = 0.0001
        return exp(log(max(start, floor)) * (1 - eased) + log(max(target, floor)) * eased)
    }

    /// Suggested slider position for `step`, given the scalars recorded for
    /// the steps before it.
    nonisolated static func suggestedScalar(step: Int, recorded: [Double]) -> Double {
        let base = suggestedScalars[min(max(step, 0), stepCount - 1)]
        let previous = recorded.prefix(max(0, step))
        switch directions[min(max(step, 0), stepCount - 1)] {
        case .reference:
            return base
        case .quieter:
            guard let lowest = previous.min() else { return base }
            return max(lowestSuggestedScalar, min(base, lowest - 2 * volumeStep))
        case .louder:
            guard let highest = previous.max() else { return base }
            return min(highestSuggestedScalar, max(base, highest + 3 * volumeStep))
        }
    }

    /// The four marks drawn under the volume slider: recorded volumes for
    /// finished steps, suggestions for the rest.
    nonisolated static func marks(recorded: [Double], drafted: [Int: Double] = [:]) -> [Double] {
        (0..<stepCount).map { step in
            if recorded.indices.contains(step) { return recorded[step] }
            return drafted[step] ?? suggestedScalar(step: step, recorded: recorded)
        }
    }

    /// Why the current volume cannot be recorded for `step`, or nil.
    nonisolated static func blocker(
        step: Int,
        reading: OutputDeviceVolumeReading,
        recordedCoordinates: [Double],
        recordedScalars: [Double] = [],
        axis: OutputDeviceVolumeReading.Axis? = nil
    ) -> String? {
        if reading.isMuted || reading.scalar <= 0 { return "当前已静音。" }
        let previous = recordedCoordinates.prefix(max(0, step))
        let previousScalars = recordedScalars.prefix(max(0, step))
        let calibrationAxis = axis ?? reading.axis
        let coordinate = reading.coordinate(on: calibrationAxis)
        let minimum = calibrationAxis == .decibels ? minimumStepDecibels : minimumStepPercent
        let minimumScalarStep = minimumStepPercent / 100
        switch directions[min(max(step, 0), stepCount - 1)] {
        case .reference:
            return nil
        case .quieter:
            let separatedByCoordinate = previous.min().map { coordinate <= $0 - minimum } ?? true
            let separatedBySlider = previousScalars.min().map { reading.scalar <= $0 - minimumScalarStep } ?? false
            guard separatedByCoordinate || separatedBySlider else {
                return "与上一步的音量过于接近，请再调低一些。"
            }
            return nil
        case .louder:
            let separatedByCoordinate = previous.max().map { coordinate >= $0 + minimum } ?? true
            let separatedBySlider = previousScalars.max().map { reading.scalar >= $0 + minimumScalarStep } ?? false
            guard separatedByCoordinate || separatedBySlider else {
                return "与参照音量过于接近，请再调高一些。"
            }
            return nil
        }
    }

    /// Switches the whole calibration to slider coordinates when device dB
    /// telemetry cannot distinguish steps that are clearly separated by the
    /// writable system-volume slider.
    nonisolated static func needsPercentageAxisFallback(
        step: Int,
        reading: OutputDeviceVolumeReading,
        recordedCoordinates: [Double],
        recordedScalars: [Double],
        axis: OutputDeviceVolumeReading.Axis
    ) -> Bool {
        guard axis == .decibels else { return false }
        let dBBlocker = blocker(
            step: step,
            reading: reading,
            recordedCoordinates: recordedCoordinates,
            axis: axis
        )
        let combinedBlocker = blocker(
            step: step,
            reading: reading,
            recordedCoordinates: recordedCoordinates,
            recordedScalars: recordedScalars,
            axis: axis
        )
        return dBBlocker != nil && combinedBlocker == nil
    }

    /// Snapping with hysteresis: a value within ±2 % of a mark takes the mark,
    /// and once held it is only released beyond ±3 %.
    nonisolated static func snapped(
        _ value: Double,
        marks: [Double],
        heldMark: Double?
    ) -> (value: Double, mark: Double?) {
        if let heldMark, abs(value - heldMark) <= snapRelease {
            return (heldMark, heldMark)
        }
        if let mark = marks.min(by: { abs($0 - value) < abs($1 - value) }),
           abs(mark - value) <= snapCapture {
            return (mark, mark)
        }
        return (value, nil)
    }
}
