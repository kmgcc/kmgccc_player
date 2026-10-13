import Foundation

/// One out-of-range or malformed value in an effect's parameters.
nonisolated struct DSPParameterIssue: Equatable, Sendable {
    let key: String
    let message: String
}

/// Typed view of a native effect's JSON parameters. The JSON object stays
/// the stored form, so unknown keys survive edits; the typed value is what
/// validation, the processor and the settings cards work with.
nonisolated protocol DSPEffectParameterSet: Equatable, Sendable {
    static var typeID: String { get }
    static var supportedParameterKeys: Set<String> { get }
    init()
    init?(json: [String: DSPJSONValue])
    func write(to json: inout [String: DSPJSONValue])
    var validationIssues: [DSPParameterIssue] { get }
}

nonisolated extension DSPNodeConfiguration {
    func effectParameters<P: DSPEffectParameterSet>(_ type: P.Type) -> P? {
        guard typeID == P.typeID else { return nil }
        return P(json: parameters)
    }

    mutating func setEffectParameters<P: DSPEffectParameterSet>(_ value: P) {
        guard typeID == P.typeID else { return }
        value.write(to: &parameters)
    }

    static func effect<P: DSPEffectParameterSet>(
        _ parameters: P,
        nodeID: UUID = UUID(),
        enabled: Bool = true
    ) -> DSPNodeConfiguration {
        var node = DSPNodeConfiguration(
            nodeID: nodeID,
            typeID: P.typeID,
            enabled: enabled,
            channelPolicy: defaultChannelPolicy(forTypeID: P.typeID),
            quality: defaultQuality(forTypeID: P.typeID)
        )
        node.setEffectParameters(parameters)
        return node
    }
}

/// Reads typed values out of a parameter object; any missing or mistyped
/// value makes the whole set unreadable.
nonisolated struct DSPParameterReader {
    let json: [String: DSPJSONValue]

    func number(_ key: String) -> Double? { json[key]?.numberValue }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value)? = json[key] else { return nil }
        return value
    }

    func string(_ key: String) -> String? {
        guard case .string(let value)? = json[key] else { return nil }
        return value
    }

    func choice<Value: RawRepresentable>(_ key: String) -> Value? where Value.RawValue == String {
        string(key).flatMap(Value.init(rawValue:))
    }

    func object(_ key: String) -> [String: DSPJSONValue]? {
        guard case .object(let value)? = json[key] else { return nil }
        return value
    }
}

/// Collects range problems with one message per parameter.
nonisolated struct DSPParameterChecker {
    private(set) var issues: [DSPParameterIssue] = []

    mutating func check(_ value: Double, in range: ClosedRange<Double>, key: String, message: String) {
        if !value.isFinite || !range.contains(value) {
            issues.append(DSPParameterIssue(key: key, message: message))
        }
    }

    /// Zero selects the automatic value; anything else must lie in `range`.
    mutating func checkAutomatic(_ value: Double, in range: ClosedRange<Double>, key: String, message: String) {
        guard value != 0 else { return }
        check(value, in: range, key: key, message: message)
    }

    mutating func fail(_ key: String, _ message: String) {
        issues.append(DSPParameterIssue(key: key, message: message))
    }
}

/// Who the bass extension is tuned for.
nonisolated enum DSPBassTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic = "auto"
    case headphones
    case speakers

    func resolved(for outputKind: DSPOutputKind?) -> DSPOutputKind {
        switch self {
        case .headphones: .headphones
        case .speakers: .speakers
        case .automatic: outputKind ?? .speakers
        }
    }
}

nonisolated enum DSPSwitchSetting: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic = "auto"
    case on
    case off
}

// MARK: - Classic virtual bass

nonisolated enum DSPBassCharacter: String, Codable, CaseIterable, Equatable, Sendable {
    /// Strong second harmonic, gentle upper series.
    case round
    /// More third and fourth harmonic.
    case tight
}

/// Harmonic synthesis tuning per transducer. Headphones still reproduce
/// much of the fundamental, so harmonics supplement it; speakers cannot,
/// so harmonics replace it and the dry low end is tightened.
nonisolated struct DSPBassProfile: Equatable, Sendable {
    let cutoffHz: Double
    let floorHz: Double
    let roundWeights: [Double]
    let tightWeights: [Double]
    let tightensDryBass: Bool
    /// Wet gain at intensity 1.
    let intensityScale: Double

    static let headphones = DSPBassProfile(
        cutoffHz: 80, floorHz: 20,
        roundWeights: [1, 0.6, 0.25, 0.1], tightWeights: [0.8, 0.8, 0.45, 0.25],
        tightensDryBass: false, intensityScale: 1
    )
    static let speakers = DSPBassProfile(
        cutoffHz: 140, floorHz: 35,
        roundWeights: [1, 0.8, 0.5, 0.3], tightWeights: [0.8, 1, 0.7, 0.5],
        tightensDryBass: true, intensityScale: 1.2
    )

    static func profile(for kind: DSPOutputKind) -> DSPBassProfile {
        kind == .headphones ? headphones : speakers
    }
}

nonisolated struct DSPClassicBassParameters: DSPEffectParameterSet {
    static let typeID = "virtualBassClassic"
    static let intensityRange: ClosedRange<Double> = 0...1
    static let cutoffRange: ClosedRange<Double> = 30...250
    static let floorRange: ClosedRange<Double> = 15...80
    static let outputTrimRange: ClosedRange<Double> = -24...6
    static let supportedParameterKeys: Set<String> = [
        "target", "intensity", "cutoffHz", "character", "floorHz", "tightenDryBass", "outputTrimDB",
    ]

    var target: DSPBassTarget = .automatic
    var intensity = 0.5
    /// 0 follows the target.
    var cutoffHz = 0.0
    var character: DSPBassCharacter = .round
    /// 0 follows the target.
    var floorHz = 0.0
    var tightenDryBass: DSPSwitchSetting = .automatic
    var outputTrimDB = 0.0

    init() {}

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let target: DSPBassTarget = reader.choice("target"),
              let intensity = reader.number("intensity"),
              let cutoffHz = reader.number("cutoffHz"),
              let character: DSPBassCharacter = reader.choice("character"),
              let floorHz = reader.number("floorHz"),
              let tightenDryBass: DSPSwitchSetting = reader.choice("tightenDryBass"),
              let outputTrimDB = reader.number("outputTrimDB") else { return nil }
        self.target = target
        self.intensity = intensity
        self.cutoffHz = cutoffHz
        self.character = character
        self.floorHz = floorHz
        self.tightenDryBass = tightenDryBass
        self.outputTrimDB = outputTrimDB
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["target"] = .string(target.rawValue)
        json["intensity"] = .number(intensity)
        json["cutoffHz"] = .number(cutoffHz)
        json["character"] = .string(character.rawValue)
        json["floorHz"] = .number(floorHz)
        json["tightenDryBass"] = .string(tightenDryBass.rawValue)
        json["outputTrimDB"] = .number(outputTrimDB)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(intensity, in: Self.intensityRange, key: "intensity", message: "强度范围为 0 至 1。")
        checker.checkAutomatic(cutoffHz, in: Self.cutoffRange, key: "cutoffHz", message: "截止频率为 0（跟随目标）或 30 至 250 Hz。")
        checker.checkAutomatic(floorHz, in: Self.floorRange, key: "floorHz", message: "下限频率为 0（跟随目标）或 15 至 80 Hz。")
        checker.check(outputTrimDB, in: Self.outputTrimRange, key: "outputTrimDB", message: "输出增益范围为 −24 至 +6 dB。")
        if cutoffHz != 0, floorHz != 0, floorHz * 1.5 > cutoffHz {
            checker.fail("floorHz", "下限频率须低于截止频率的三分之二。")
        }
        return checker.issues
    }

    /// Profile, cutoff and floor the processor actually uses on `outputKind`.
    func resolved(for outputKind: DSPOutputKind?) -> (profile: DSPBassProfile, cutoffHz: Double, floorHz: Double) {
        let profile = DSPBassProfile.profile(for: target.resolved(for: outputKind))
        let cutoff = cutoffHz == 0 ? profile.cutoffHz : cutoffHz
        var floor = floorHz == 0 ? profile.floorHz : floorHz
        floor = min(floor, cutoff / 1.5)
        return (profile, cutoff, floor)
    }
}

// MARK: - Hybrid virtual bass

nonisolated struct DSPHybridBassParameters: DSPEffectParameterSet {
    static let typeID = "virtualBassHybrid"
    static let intensityRange: ClosedRange<Double> = 0...1
    static let cutoffRange: ClosedRange<Double> = 40...200
    static let transientRange: ClosedRange<Double> = 0...1
    static let harmonicCountRange: ClosedRange<Double> = 2...8
    static let toleranceRange: ClosedRange<Double> = 0.01...0.2
    static let timbreSlopeRange: ClosedRange<Double> = 0...24
    static let outputTrimRange: ClosedRange<Double> = -24...6
    static let supportedParameterKeys: Set<String> = [
        "target", "intensity", "cutoffHz", "transient", "harmonicCount", "harmonicTolerance",
        "timbreLowDBPerOctave", "timbreHighDBPerOctave", "tightenDryBass", "outputTrimDB",
    ]

    var target: DSPBassTarget = .automatic
    var intensity = 0.5
    /// 0 follows the target.
    var cutoffHz = 0.0
    /// Gain of the transient branch relative to its nominal 10 dB.
    var transient = 0.5
    var harmonicCount = 5.0
    var harmonicTolerance = 0.05
    var timbreLowDBPerOctave = 10.0
    var timbreHighDBPerOctave = 3.0
    var tightenDryBass: DSPSwitchSetting = .automatic
    var outputTrimDB = 0.0

    init() {}

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let target: DSPBassTarget = reader.choice("target"),
              let intensity = reader.number("intensity"),
              let cutoffHz = reader.number("cutoffHz"),
              let transient = reader.number("transient"),
              let harmonicCount = reader.number("harmonicCount"),
              let harmonicTolerance = reader.number("harmonicTolerance"),
              let timbreLow = reader.number("timbreLowDBPerOctave"),
              let timbreHigh = reader.number("timbreHighDBPerOctave"),
              let tightenDryBass: DSPSwitchSetting = reader.choice("tightenDryBass"),
              let outputTrimDB = reader.number("outputTrimDB") else { return nil }
        self.target = target
        self.intensity = intensity
        self.cutoffHz = cutoffHz
        self.transient = transient
        self.harmonicCount = harmonicCount
        self.harmonicTolerance = harmonicTolerance
        timbreLowDBPerOctave = timbreLow
        timbreHighDBPerOctave = timbreHigh
        self.tightenDryBass = tightenDryBass
        self.outputTrimDB = outputTrimDB
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["target"] = .string(target.rawValue)
        json["intensity"] = .number(intensity)
        json["cutoffHz"] = .number(cutoffHz)
        json["transient"] = .number(transient)
        json["harmonicCount"] = .number(harmonicCount)
        json["harmonicTolerance"] = .number(harmonicTolerance)
        json["timbreLowDBPerOctave"] = .number(timbreLowDBPerOctave)
        json["timbreHighDBPerOctave"] = .number(timbreHighDBPerOctave)
        json["tightenDryBass"] = .string(tightenDryBass.rawValue)
        json["outputTrimDB"] = .number(outputTrimDB)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(intensity, in: Self.intensityRange, key: "intensity", message: "强度范围为 0 至 1。")
        checker.checkAutomatic(cutoffHz, in: Self.cutoffRange, key: "cutoffHz", message: "截止频率为 0（跟随目标）或 40 至 200 Hz。")
        checker.check(transient, in: Self.transientRange, key: "transient", message: "瞬态范围为 0 至 1。")
        checker.check(harmonicCount, in: Self.harmonicCountRange, key: "harmonicCount", message: "谐波数范围为 2 至 8。")
        if harmonicCount.isFinite, harmonicCount != harmonicCount.rounded() {
            checker.fail("harmonicCount", "谐波数须为整数。")
        }
        checker.check(harmonicTolerance, in: Self.toleranceRange, key: "harmonicTolerance", message: "谐波容差范围为 0.01 至 0.2。")
        checker.check(timbreLowDBPerOctave, in: Self.timbreSlopeRange, key: "timbreLowDBPerOctave", message: "音色斜率范围为 0 至 24 dB/倍频程。")
        checker.check(timbreHighDBPerOctave, in: Self.timbreSlopeRange, key: "timbreHighDBPerOctave", message: "音色斜率范围为 0 至 24 dB/倍频程。")
        checker.check(outputTrimDB, in: Self.outputTrimRange, key: "outputTrimDB", message: "输出增益范围为 −24 至 +6 dB。")
        return checker.issues
    }

    func resolvedCutoff(for outputKind: DSPOutputKind?) -> (kind: DSPOutputKind, cutoffHz: Double) {
        let kind = target.resolved(for: outputKind)
        // The paper's frequency range: harmonics are generated for
        // fundamentals below the cutoff, which tracks the transducer.
        let automatic = kind == .headphones ? 80.0 : 140.0
        return (kind, cutoffHz == 0 ? automatic : cutoffHz)
    }
}

// MARK: - Stereo width

nonisolated struct DSPStereoWidthParameters: DSPEffectParameterSet {
    static let typeID = DSPNodeConfiguration.stereoWidthTypeID
    static let widthRange: ClosedRange<Double> = 0...3
    static let crossoverRange: ClosedRange<Double> = 60...400
    static let lowWidthRatioRange: ClosedRange<Double> = 0...1
    static let maximumSideRatioRange: ClosedRange<Double> = 0.2...1.5
    static let outputTrimRange: ClosedRange<Double> = -24...6
    static let supportedParameterKeys: Set<String> = [
        "width", "crossoverHz", "lowWidthRatio", "maximumSideRatio", "loudnessMatchEnabled", "outputTrimDB",
    ]

    var width = 1.4
    /// Centre of the side-channel low shelf that restrains bass widening.
    var crossoverHz = 150.0
    /// Share of the added width kept below the crossover.
    var lowWidthRatio = 0.2
    /// Highest side-to-mid energy ratio widening may reach above the
    /// crossover. At 1 the channels are on average uncorrelated; beyond it
    /// the out-of-phase part starts to dominate and the image turns hollow.
    var maximumSideRatio = 1.0
    var loudnessMatchEnabled = true
    var outputTrimDB = 0.0

    init() {}

    init(width: Double, outputTrimDB: Double = 0) {
        self.width = width
        self.outputTrimDB = outputTrimDB
    }

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let width = reader.number("width"),
              let crossoverHz = reader.number("crossoverHz"),
              let lowWidthRatio = reader.number("lowWidthRatio"),
              let maximumSideRatio = reader.number("maximumSideRatio"),
              let loudnessMatchEnabled = reader.bool("loudnessMatchEnabled"),
              let outputTrimDB = reader.number("outputTrimDB") else { return nil }
        self.width = width
        self.crossoverHz = crossoverHz
        self.lowWidthRatio = lowWidthRatio
        self.maximumSideRatio = maximumSideRatio
        self.loudnessMatchEnabled = loudnessMatchEnabled
        self.outputTrimDB = outputTrimDB
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["width"] = .number(width)
        json["crossoverHz"] = .number(crossoverHz)
        json["lowWidthRatio"] = .number(lowWidthRatio)
        json["maximumSideRatio"] = .number(maximumSideRatio)
        json["loudnessMatchEnabled"] = .bool(loudnessMatchEnabled)
        json["outputTrimDB"] = .number(outputTrimDB)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(width, in: Self.widthRange, key: "width", message: "宽度范围为 0 至 3。")
        checker.check(crossoverHz, in: Self.crossoverRange, key: "crossoverHz", message: "低频收束频率范围为 60 至 400 Hz。")
        checker.check(lowWidthRatio, in: Self.lowWidthRatioRange, key: "lowWidthRatio", message: "低频宽度比例范围为 0 至 1。")
        checker.check(maximumSideRatio, in: Self.maximumSideRatioRange, key: "maximumSideRatio", message: "最大侧中比范围为 0.2 至 1.5。")
        checker.check(outputTrimDB, in: Self.outputTrimRange, key: "outputTrimDB", message: "输出增益范围为 −24 至 +6 dB。")
        return checker.issues
    }
}

// MARK: - Tube

nonisolated enum DSPTubeMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// Biased hyperbolic-tangent saturation of the whole signal.
    case classic
    /// Band-limited low-order harmonics added to an untouched dry path.
    case hifi
}

nonisolated struct DSPTubeParameters: DSPEffectParameterSet {
    static let typeID = DSPNodeConfiguration.tubeTypeID
    static let driveRange: ClosedRange<Double> = 0...18
    static let biasRange: ClosedRange<Double> = -0.5...0.5
    static let mixRange: ClosedRange<Double> = 0...1
    static let hifiAmountRange: ClosedRange<Double> = 0...1
    static let inputTrimRange: ClosedRange<Double> = -24...12
    static let outputTrimRange: ClosedRange<Double> = -24...6
    static let dcBlockFrequencyRange: ClosedRange<Double> = 5...40
    static let supportedParameterKeys: Set<String> = [
        "mode", "driveDB", "bias", "mix", "hifiAmount", "inputTrimDB", "outputTrimDB",
        "dcRemovalEnabled", "dcBlockHz",
    ]

    var mode: DSPTubeMode = .classic
    var driveDB = 6.0
    var bias = 0.15
    var mix = 0.5
    var hifiAmount = 0.4
    var inputTrimDB = 0.0
    var outputTrimDB = 0.0
    var dcRemovalEnabled = true
    var dcBlockHz = 10.0

    init() {}

    init(
        mode: DSPTubeMode = .classic,
        driveDB: Double = 6,
        bias: Double = 0.15,
        mix: Double = 0.5,
        hifiAmount: Double = 0.4,
        inputTrimDB: Double = 0,
        outputTrimDB: Double = 0,
        dcRemovalEnabled: Bool = true,
        dcBlockHz: Double = 10
    ) {
        self.mode = mode
        self.driveDB = driveDB
        self.bias = bias
        self.mix = mix
        self.hifiAmount = hifiAmount
        self.inputTrimDB = inputTrimDB
        self.outputTrimDB = outputTrimDB
        self.dcRemovalEnabled = dcRemovalEnabled
        self.dcBlockHz = dcBlockHz
    }

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let mode: DSPTubeMode = reader.choice("mode"),
              let driveDB = reader.number("driveDB"),
              let bias = reader.number("bias"),
              let mix = reader.number("mix"),
              let hifiAmount = reader.number("hifiAmount"),
              let inputTrimDB = reader.number("inputTrimDB"),
              let outputTrimDB = reader.number("outputTrimDB"),
              let dcRemovalEnabled = reader.bool("dcRemovalEnabled"),
              let dcBlockHz = reader.number("dcBlockHz") else { return nil }
        self.init(mode: mode, driveDB: driveDB, bias: bias, mix: mix, hifiAmount: hifiAmount,
                  inputTrimDB: inputTrimDB, outputTrimDB: outputTrimDB,
                  dcRemovalEnabled: dcRemovalEnabled, dcBlockHz: dcBlockHz)
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["mode"] = .string(mode.rawValue)
        json["driveDB"] = .number(driveDB)
        json["bias"] = .number(bias)
        json["mix"] = .number(mix)
        json["hifiAmount"] = .number(hifiAmount)
        json["inputTrimDB"] = .number(inputTrimDB)
        json["outputTrimDB"] = .number(outputTrimDB)
        json["dcRemovalEnabled"] = .bool(dcRemovalEnabled)
        json["dcBlockHz"] = .number(dcBlockHz)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(driveDB, in: Self.driveRange, key: "driveDB", message: "驱动范围为 0 至 18 dB。")
        checker.check(bias, in: Self.biasRange, key: "bias", message: "不对称范围为 −0.5 至 +0.5。")
        checker.check(mix, in: Self.mixRange, key: "mix", message: "混合范围为 0 至 1。")
        checker.check(hifiAmount, in: Self.hifiAmountRange, key: "hifiAmount", message: "强度范围为 0 至 1。")
        checker.check(inputTrimDB, in: Self.inputTrimRange, key: "inputTrimDB", message: "输入增益范围为 −24 至 +12 dB。")
        checker.check(outputTrimDB, in: Self.outputTrimRange, key: "outputTrimDB", message: "输出增益范围为 −24 至 +6 dB。")
        checker.check(dcBlockHz, in: Self.dcBlockFrequencyRange, key: "dcBlockHz", message: "直流阻隔频率范围为 5 至 40 Hz。")
        return checker.issues
    }

    /// True when the settings leave the signal untouched apart from trims.
    var isDry: Bool {
        mode == .classic ? mix == 0 : hifiAmount == 0
    }
}

// MARK: - Crossfeed

nonisolated enum DSPCrossfeedStrength: String, Codable, CaseIterable, Equatable, Sendable {
    case light
    case medium
    case strong

    /// bs2b presets. `feedDB` is how far below the near ear the opposite
    /// ear hears the bass, so a smaller value feeds more: Jan Meier
    /// (650 Hz, 9.5 dB) is the lightest, Chu Moy (700 Hz, 6 dB) the middle
    /// and bs2b's default (700 Hz, 4.5 dB) the strongest.
    var preset: (cutoffHz: Double, feedDB: Double) {
        switch self {
        case .light: (650, 9.5)
        case .medium: (700, 6)
        case .strong: (700, 4.5)
        }
    }
}

nonisolated struct DSPCrossfeedParameters: DSPEffectParameterSet {
    static let typeID = "crossfeed"
    static let cutoffRange: ClosedRange<Double> = 300...1_000
    static let feedRange: ClosedRange<Double> = 1...15
    static let supportedParameterKeys: Set<String> = ["strength", "cutoffHz", "feedDB"]

    /// The preset the cutoff and feed were last taken from.
    var strength: DSPCrossfeedStrength = .medium
    var cutoffHz = 700.0
    var feedDB = 6.0

    init() {}

    init(strength: DSPCrossfeedStrength) {
        self.strength = strength
        cutoffHz = strength.preset.cutoffHz
        feedDB = strength.preset.feedDB
    }

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let strength: DSPCrossfeedStrength = reader.choice("strength"),
              let cutoffHz = reader.number("cutoffHz"),
              let feedDB = reader.number("feedDB") else { return nil }
        self.strength = strength
        self.cutoffHz = cutoffHz
        self.feedDB = feedDB
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["strength"] = .string(strength.rawValue)
        json["cutoffHz"] = .number(cutoffHz)
        json["feedDB"] = .number(feedDB)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(cutoffHz, in: Self.cutoffRange, key: "cutoffHz", message: "截止频率范围为 300 至 1000 Hz。")
        checker.check(feedDB, in: Self.feedRange, key: "feedDB", message: "混入电平范围为 1 至 15 dB。")
        return checker.issues
    }
}

// MARK: - Spatial audio

nonisolated enum DSPSpatialSource: String, Codable, CaseIterable, Equatable, Sendable {
    case room
    case impulseResponse
}

/// The room around the virtual speakers. Spatial audio keeps the room
/// quiet; spaces to hear belong to the reverb node.
nonisolated enum DSPRoomPreset: String, Codable, CaseIterable, Equatable, Sendable {
    /// Speakers alone, without walls.
    case none
    /// A small treated listening room.
    case studio
}

nonisolated struct DSPSpatialAudioParameters: DSPEffectParameterSet {
    static let typeID = "spatialAudio"
    static let distanceRange: ClosedRange<Double> = 1...8
    static let speakerAngleRange: ClosedRange<Double> = 20...45
    static let mixRange: ClosedRange<Double> = 0...1
    static let outputTrimRange: ClosedRange<Double> = -24...6
    static let supportedParameterKeys: Set<String> = [
        "source", "room", "distanceM", "speakerAngleDeg", "impulseResponseID", "impulseResponseName",
        "mix", "loudnessMatchEnabled", "outputTrimDB",
    ]

    var source: DSPSpatialSource = .room
    var room: DSPRoomPreset = .studio
    var distanceM = 2.0
    var speakerAngleDeg = 30.0
    /// Content hash of an imported impulse response; empty when none.
    var impulseResponseID = ""
    var impulseResponseName = ""
    var mix = 1.0
    var loudnessMatchEnabled = true
    var outputTrimDB = 0.0

    init() {}

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let source: DSPSpatialSource = reader.choice("source"),
              let room: DSPRoomPreset = reader.choice("room"),
              let distanceM = reader.number("distanceM"),
              let speakerAngleDeg = reader.number("speakerAngleDeg"),
              let impulseResponseID = reader.string("impulseResponseID"),
              let impulseResponseName = reader.string("impulseResponseName"),
              let mix = reader.number("mix"),
              let loudnessMatchEnabled = reader.bool("loudnessMatchEnabled"),
              let outputTrimDB = reader.number("outputTrimDB") else { return nil }
        self.source = source
        self.room = room
        self.distanceM = distanceM
        self.speakerAngleDeg = speakerAngleDeg
        self.impulseResponseID = impulseResponseID
        self.impulseResponseName = impulseResponseName
        self.mix = mix
        self.loudnessMatchEnabled = loudnessMatchEnabled
        self.outputTrimDB = outputTrimDB
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["source"] = .string(source.rawValue)
        json["room"] = .string(room.rawValue)
        json["distanceM"] = .number(distanceM)
        json["speakerAngleDeg"] = .number(speakerAngleDeg)
        json["impulseResponseID"] = .string(impulseResponseID)
        json["impulseResponseName"] = .string(impulseResponseName)
        json["mix"] = .number(mix)
        json["loudnessMatchEnabled"] = .bool(loudnessMatchEnabled)
        json["outputTrimDB"] = .number(outputTrimDB)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(distanceM, in: Self.distanceRange, key: "distanceM", message: "距离范围为 1 至 8 米。")
        checker.check(speakerAngleDeg, in: Self.speakerAngleRange, key: "speakerAngleDeg", message: "音箱角度范围为 20° 至 45°。")
        checker.check(mix, in: Self.mixRange, key: "mix", message: "混合范围为 0 至 1。")
        checker.check(outputTrimDB, in: Self.outputTrimRange, key: "outputTrimDB", message: "输出增益范围为 −24 至 +6 dB。")
        if !impulseResponseID.isEmpty,
           impulseResponseID.count != 64 || !impulseResponseID.allSatisfy(\.isHexDigit) {
            checker.fail("impulseResponseID", "脉冲响应标识无效。")
        }
        return checker.issues
    }
}

// MARK: - Reverb

nonisolated enum DSPReverbSpace: String, Codable, CaseIterable, Equatable, Sendable {
    case room
    case studio
    case plate
    case hall

    /// Values the space picker writes into the hidden parameters.
    var defaults: (preDelayMs: Double, lowDecayRatio: Double, highDecayRatio: Double) {
        switch self {
        case .room: (8, 1.15, 0.55)
        case .studio: (4, 1.0, 0.7)
        case .plate: (0, 1.0, 0.8)
        case .hall: (24, 1.3, 0.5)
        }
    }

    /// Mid-band decay time at size 0 and size 1, in seconds.
    var decayRange: ClosedRange<Double> {
        switch self {
        case .room: 0.3...1.2
        case .studio: 0.15...0.7
        case .plate: 0.6...4
        case .hall: 1.2...4.5
        }
    }
}

nonisolated struct DSPReverbParameters: DSPEffectParameterSet {
    static let typeID = "reverb"
    static let sizeRange: ClosedRange<Double> = 0...1
    static let mixRange: ClosedRange<Double> = 0...1
    static let toneRange: ClosedRange<Double> = -1...1
    static let preDelayRange: ClosedRange<Double> = 0...200
    static let lowCutRange: ClosedRange<Double> = 20...500
    static let widthRange: ClosedRange<Double> = 0...1
    static let lowDecayRatioRange: ClosedRange<Double> = 0.5...2
    static let highDecayRatioRange: ClosedRange<Double> = 0.1...1.5
    static let supportedParameterKeys: Set<String> = [
        "space", "size", "mix", "tone", "preDelayMs", "lowCutHz", "width", "lowDecayRatio", "highDecayRatio",
    ]

    var space: DSPReverbSpace = .room
    var size = 0.5
    var mix = 0.15
    /// −1 darker, +1 brighter.
    var tone = 0.0
    var preDelayMs = 8.0
    var lowCutHz = 150.0
    var width = 1.0
    var lowDecayRatio = 1.15
    var highDecayRatio = 0.55

    init() {}

    init(space: DSPReverbSpace) {
        self.space = space
        preDelayMs = space.defaults.preDelayMs
        lowDecayRatio = space.defaults.lowDecayRatio
        highDecayRatio = space.defaults.highDecayRatio
    }

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let space: DSPReverbSpace = reader.choice("space"),
              let size = reader.number("size"),
              let mix = reader.number("mix"),
              let tone = reader.number("tone"),
              let preDelayMs = reader.number("preDelayMs"),
              let lowCutHz = reader.number("lowCutHz"),
              let width = reader.number("width"),
              let lowDecayRatio = reader.number("lowDecayRatio"),
              let highDecayRatio = reader.number("highDecayRatio") else { return nil }
        self.space = space
        self.size = size
        self.mix = mix
        self.tone = tone
        self.preDelayMs = preDelayMs
        self.lowCutHz = lowCutHz
        self.width = width
        self.lowDecayRatio = lowDecayRatio
        self.highDecayRatio = highDecayRatio
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["space"] = .string(space.rawValue)
        json["size"] = .number(size)
        json["mix"] = .number(mix)
        json["tone"] = .number(tone)
        json["preDelayMs"] = .number(preDelayMs)
        json["lowCutHz"] = .number(lowCutHz)
        json["width"] = .number(width)
        json["lowDecayRatio"] = .number(lowDecayRatio)
        json["highDecayRatio"] = .number(highDecayRatio)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(size, in: Self.sizeRange, key: "size", message: "大小范围为 0 至 1。")
        checker.check(mix, in: Self.mixRange, key: "mix", message: "混合范围为 0 至 1。")
        checker.check(tone, in: Self.toneRange, key: "tone", message: "明暗范围为 −1 至 +1。")
        checker.check(preDelayMs, in: Self.preDelayRange, key: "preDelayMs", message: "预延迟范围为 0 至 200 ms。")
        checker.check(lowCutHz, in: Self.lowCutRange, key: "lowCutHz", message: "低切频率范围为 20 至 500 Hz。")
        checker.check(width, in: Self.widthRange, key: "width", message: "宽度范围为 0 至 1。")
        checker.check(lowDecayRatio, in: Self.lowDecayRatioRange, key: "lowDecayRatio", message: "低频衰减比例范围为 0.5 至 2。")
        checker.check(highDecayRatio, in: Self.highDecayRatioRange, key: "highDecayRatio", message: "高频衰减比例范围为 0.1 至 1.5。")
        return checker.issues
    }

    /// Mid-band 60 dB decay time, from the space and its size.
    var midDecaySeconds: Double {
        let range = space.decayRange
        // Size spreads geometrically: equal steps sound like equal changes.
        let clamped = min(max(size, 0), 1)
        return range.lowerBound * pow(range.upperBound / range.lowerBound, clamped)
    }

    /// High-band decay ratio after the tone control: darker shortens the top.
    var effectiveHighDecayRatio: Double {
        min(1.5, max(0.1, highDecayRatio * pow(2, tone)))
    }
}

// MARK: - Compressor

nonisolated enum DSPCompressorStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case gentle
    case night
    case custom
}

nonisolated enum DSPCompressorSpeed: String, Codable, CaseIterable, Equatable, Sendable {
    case fast
    case medium
    case slow

    /// Attack and release time constants, in milliseconds.
    var times: (attackMs: Double, releaseMs: Double) {
        switch self {
        case .fast: (3, 60)
        case .medium: (10, 150)
        case .slow: (30, 400)
        }
    }
}

nonisolated struct DSPCompressorBand: Equatable, Sendable {
    static let thresholdRange: ClosedRange<Double> = -60...0
    static let ratioRange: ClosedRange<Double> = 1...20
    static let gainRange: ClosedRange<Double> = -12...12

    var thresholdDB: Double
    var ratio: Double
    var gainDB: Double

    init(thresholdDB: Double, ratio: Double, gainDB: Double = 0) {
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.gainDB = gainDB
    }

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let thresholdDB = reader.number("thresholdDB"),
              let ratio = reader.number("ratio"),
              let gainDB = reader.number("gainDB") else { return nil }
        self.init(thresholdDB: thresholdDB, ratio: ratio, gainDB: gainDB)
    }

    var json: DSPJSONValue {
        .object(["thresholdDB": .number(thresholdDB), "ratio": .number(ratio), "gainDB": .number(gainDB)])
    }
}

/// Band order shared by the parameters, the kernel and the card.
nonisolated enum DSPCompressorBandKey: String, CaseIterable, Sendable {
    case low
    case mid
    case high
    case master
}

nonisolated struct DSPCompressorParameters: DSPEffectParameterSet {
    static let typeID = "compressor"
    static let lowCrossoverRange: ClosedRange<Double> = 40...1_000
    static let highCrossoverRange: ClosedRange<Double> = 1_000...12_000
    static let kneeRange: ClosedRange<Double> = 0...24
    static let lookaheadRange: ClosedRange<Double> = 0...10
    static let outputTrimRange: ClosedRange<Double> = -24...6
    static let supportedParameterKeys: Set<String> = [
        "style", "speed", "lowCrossoverHz", "highCrossoverHz", "bands", "kneeDB", "lookaheadMs",
        "loudnessMatchEnabled", "outputTrimDB",
    ]

    var style: DSPCompressorStyle = .gentle
    var speed: DSPCompressorSpeed = .medium
    var lowCrossoverHz = 200.0
    var highCrossoverHz = 2_500.0
    var bands: [DSPCompressorBand] = DSPCompressorStyle.gentle.bands
    var kneeDB = 6.0
    var lookaheadMs = 0.0
    var loudnessMatchEnabled = true
    var outputTrimDB = 0.0

    init() {}

    init(style: DSPCompressorStyle) {
        self.style = style
        bands = style.bands
    }

    init?(json: [String: DSPJSONValue]) {
        let reader = DSPParameterReader(json: json)
        guard let style: DSPCompressorStyle = reader.choice("style"),
              let speed: DSPCompressorSpeed = reader.choice("speed"),
              let lowCrossoverHz = reader.number("lowCrossoverHz"),
              let highCrossoverHz = reader.number("highCrossoverHz"),
              let bandObject = reader.object("bands"),
              let kneeDB = reader.number("kneeDB"),
              let lookaheadMs = reader.number("lookaheadMs"),
              let loudnessMatchEnabled = reader.bool("loudnessMatchEnabled"),
              let outputTrimDB = reader.number("outputTrimDB") else { return nil }
        var bands: [DSPCompressorBand] = []
        for key in DSPCompressorBandKey.allCases {
            guard case .object(let fields)? = bandObject[key.rawValue],
                  let band = DSPCompressorBand(json: fields) else { return nil }
            bands.append(band)
        }
        self.style = style
        self.speed = speed
        self.lowCrossoverHz = lowCrossoverHz
        self.highCrossoverHz = highCrossoverHz
        self.bands = bands
        self.kneeDB = kneeDB
        self.lookaheadMs = lookaheadMs
        self.loudnessMatchEnabled = loudnessMatchEnabled
        self.outputTrimDB = outputTrimDB
    }

    func write(to json: inout [String: DSPJSONValue]) {
        json["style"] = .string(style.rawValue)
        json["speed"] = .string(speed.rawValue)
        json["lowCrossoverHz"] = .number(lowCrossoverHz)
        json["highCrossoverHz"] = .number(highCrossoverHz)
        var bandObject: [String: DSPJSONValue] = [:]
        for (key, band) in zip(DSPCompressorBandKey.allCases, bands) {
            bandObject[key.rawValue] = band.json
        }
        json["bands"] = .object(bandObject)
        json["kneeDB"] = .number(kneeDB)
        json["lookaheadMs"] = .number(lookaheadMs)
        json["loudnessMatchEnabled"] = .bool(loudnessMatchEnabled)
        json["outputTrimDB"] = .number(outputTrimDB)
    }

    var validationIssues: [DSPParameterIssue] {
        var checker = DSPParameterChecker()
        checker.check(lowCrossoverHz, in: Self.lowCrossoverRange, key: "lowCrossoverHz", message: "低分频点范围为 40 至 1000 Hz。")
        checker.check(highCrossoverHz, in: Self.highCrossoverRange, key: "highCrossoverHz", message: "高分频点范围为 1000 至 12000 Hz。")
        if lowCrossoverHz.isFinite, highCrossoverHz.isFinite, highCrossoverHz < lowCrossoverHz * 2 {
            checker.fail("highCrossoverHz", "高分频点至少比低分频点高一个倍频程。")
        }
        if bands.count != DSPCompressorBandKey.allCases.count {
            checker.fail("bands", "压缩需要低、中、高与总四组参数。")
        }
        for (key, band) in zip(DSPCompressorBandKey.allCases, bands) {
            let path = "bands.\(key.rawValue)"
            checker.check(band.thresholdDB, in: DSPCompressorBand.thresholdRange, key: "\(path).thresholdDB", message: "阈值范围为 −60 至 0 dB。")
            checker.check(band.ratio, in: DSPCompressorBand.ratioRange, key: "\(path).ratio", message: "比率范围为 1 至 20。")
            checker.check(band.gainDB, in: DSPCompressorBand.gainRange, key: "\(path).gainDB", message: "增益范围为 −12 至 +12 dB。")
        }
        checker.check(kneeDB, in: Self.kneeRange, key: "kneeDB", message: "拐点宽度范围为 0 至 24 dB。")
        checker.check(lookaheadMs, in: Self.lookaheadRange, key: "lookaheadMs", message: "前瞻范围为 0 至 10 ms。")
        checker.check(outputTrimDB, in: Self.outputTrimRange, key: "outputTrimDB", message: "输出增益范围为 −24 至 +6 dB。")
        return checker.issues
    }

    func band(_ key: DSPCompressorBandKey) -> DSPCompressorBand {
        bands[DSPCompressorBandKey.allCases.firstIndex(of: key)!]
    }
}

nonisolated extension DSPCompressorStyle {
    /// Low, mid, high and master settings the style picker writes.
    var bands: [DSPCompressorBand] {
        switch self {
        case .gentle, .custom:
            [
                DSPCompressorBand(thresholdDB: -24, ratio: 2),
                DSPCompressorBand(thresholdDB: -22, ratio: 1.8),
                DSPCompressorBand(thresholdDB: -26, ratio: 2),
                DSPCompressorBand(thresholdDB: -14, ratio: 1.5),
            ]
        case .night:
            [
                DSPCompressorBand(thresholdDB: -32, ratio: 3),
                DSPCompressorBand(thresholdDB: -30, ratio: 2.5),
                DSPCompressorBand(thresholdDB: -32, ratio: 3),
                DSPCompressorBand(thresholdDB: -22, ratio: 4),
            ]
        }
    }
}
