//
//  AudioDSPModels.swift
//  myPlayer2
//
//  Value types shared by the DSP controller, preset store, and renderer.
//

import AudioToolbox
import Foundation

nonisolated enum DSPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([DSPJSONValue])
    case object([String: DSPJSONValue])

    nonisolated static func == (lhs: DSPJSONValue, rhs: DSPJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let left), .bool(let right)):
            return left == right
        case (.integer(let left), .integer(let right)):
            return left == right
        case (.unsignedInteger(let left), .unsignedInteger(let right)):
            return left == right
        case (.integer(let left), .unsignedInteger(let right)):
            return left >= 0 && UInt64(left) == right
        case (.unsignedInteger(let left), .integer(let right)):
            return right >= 0 && left == UInt64(right)
        case (.number(let left), .number(let right)):
            return left == right
        case (.integer(let left), .number(let right)):
            return Int64(exactly: right) == left
        case (.number(let left), .integer(let right)):
            return Int64(exactly: left) == right
        case (.unsignedInteger(let left), .number(let right)):
            return UInt64(exactly: right) == left
        case (.number(let left), .unsignedInteger(let right)):
            return UInt64(exactly: left) == right
        case (.string(let left), .string(let right)):
            return left == right
        case (.array(let left), .array(let right)):
            return left == right
        case (.object(let left), .object(let right)):
            return left == right
        default:
            return false
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DSPJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DSPJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }

    nonisolated var numberValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .unsignedInteger(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
}

nonisolated enum DSPFilterType: String, Codable, CaseIterable, Equatable, Sendable {
    case bell
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch

    nonisolated var usesGain: Bool {
        self == .bell || self == .lowShelf || self == .highShelf
    }

    nonisolated var usesSlope: Bool {
        self == .lowShelf || self == .highShelf
    }
}

nonisolated struct DSPParametricEQBand: Codable, Equatable, Sendable {
    nonisolated static let frequencyRange: ClosedRange<Double> = 20...20_000
    nonisolated static let gainRange: ClosedRange<Double> = -18...18
    nonisolated static let qRange: ClosedRange<Double> = 0.25...16
    nonisolated static let shelfSlopeRange: ClosedRange<Double> = 0.25...1
    nonisolated static let defaultBands: [DSPParametricEQBand] = [
        DSPParametricEQBand(type: .highPass, frequencyHz: 70),
        DSPParametricEQBand(frequencyHz: 120),
        DSPParametricEQBand(frequencyHz: 250),
        DSPParametricEQBand(frequencyHz: 500),
        DSPParametricEQBand(frequencyHz: 1_000),
        DSPParametricEQBand(frequencyHz: 2_000),
        DSPParametricEQBand(frequencyHz: 4_000),
        DSPParametricEQBand(frequencyHz: 8_000),
        DSPParametricEQBand(type: .highShelf, frequencyHz: 12_000),
        DSPParametricEQBand(frequencyHz: 16_000),
    ]

    var enabled: Bool
    var type: DSPFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    nonisolated init(
        enabled: Bool = false,
        type: DSPFilterType = .bell,
        frequencyHz: Double,
        gainDB: Double = 0,
        q: Double = 0.71
    ) {
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }

    nonisolated var normalized: DSPParametricEQBand {
        var result = self
        result.frequencyHz = Self.clamp(
            Self.finiteOrDefault(frequencyHz, fallback: 1_000),
            to: Self.frequencyRange
        )
        result.gainDB = Self.clamp(
            Self.finiteOrDefault(gainDB, fallback: 0),
            to: Self.gainRange
        )
        let qRange = type.usesSlope ? Self.shelfSlopeRange : Self.qRange
        result.q = Self.clamp(Self.finiteOrDefault(q, fallback: 0.71), to: qRange)
        return result
    }

    nonisolated private static func finiteOrDefault(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    nonisolated private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

nonisolated enum DSPHeadroomMode: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case off
}

/// Automatic headroom cuts the chain input by the boost the linear stages
/// and input gain add, never by more than `maximumAttenuationDB`. The output
/// gain stays the listener's own level; the safety limiter catches the rest.
nonisolated struct DSPHeadroomConfiguration: Codable, Equatable, Sendable {
    nonisolated static let maximumAttenuationRange: ClosedRange<Double> = 0...12
    nonisolated static let defaultMaximumAttenuationDB = 10.0

    var mode: DSPHeadroomMode
    var maximumAttenuationDB: Double

    private enum CodingKeys: String, CodingKey {
        case mode
        case maximumAttenuationDB
    }

    nonisolated init(
        mode: DSPHeadroomMode = .automatic,
        maximumAttenuationDB: Double = Self.defaultMaximumAttenuationDB
    ) {
        self.mode = mode
        self.maximumAttenuationDB = maximumAttenuationDB
    }

    /// Presets saved with the former safety margin take the default ceiling.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(DSPHeadroomMode.self, forKey: .mode)
        maximumAttenuationDB = try container.decodeIfPresent(Double.self, forKey: .maximumAttenuationDB)
            ?? Self.defaultMaximumAttenuationDB
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(maximumAttenuationDB, forKey: .maximumAttenuationDB)
    }
}

/// Lookahead peak limiter after the equal-loudness stage. Its ceiling is
/// measured after the output gain, so the chain never leaves above it.
nonisolated struct DSPLimiterConfiguration: Codable, Equatable, Sendable {
    /// Identity of the limiter inside the processor chain.
    nonisolated static let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    nonisolated static let ceilingRange: ClosedRange<Double> = -6...0
    nonisolated static let defaultCeilingDB = 0.0
    nonisolated static let fixedReleaseMilliseconds = 250.0

    var enabled: Bool
    /// Sample-peak ceiling of the final output, in dBFS.
    var ceilingDB: Double

    private enum CodingKeys: String, CodingKey {
        case enabled, ceilingDB
    }

    nonisolated init(
        enabled: Bool = true,
        ceilingDB: Double = Self.defaultCeilingDB
    ) {
        self.enabled = enabled
        self.ceilingDB = ceilingDB
    }

    /// Presets saved with only the switch take the default ceiling.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        ceilingDB = try container.decodeIfPresent(Double.self, forKey: .ceilingDB) ?? Self.defaultCeilingDB
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(ceilingDB, forKey: .ceilingDB)
    }
}

nonisolated struct DSPNodeConfiguration: Codable, Equatable, Sendable {
    nonisolated static let parametricEQTypeID = "peq9"
    /// Runtime type of the fixed equal-loudness stage inside the processor.
    /// It is never a member of `AudioDSPConfiguration.nodes`.
    nonisolated static let equalLoudnessTypeID = "equalLoudness"
    nonisolated static let stereoWidthTypeID = "stereoWidth"
    nonisolated static let classicBassTypeID = DSPClassicBassParameters.typeID
    nonisolated static let hybridBassTypeID = DSPHybridBassParameters.typeID
    nonisolated static let tubeTypeID = "tube"
    nonisolated static let crossfeedTypeID = DSPCrossfeedParameters.typeID
    nonisolated static let spatialAudioTypeID = DSPSpatialAudioParameters.typeID
    nonisolated static let reverbTypeID = DSPReverbParameters.typeID
    nonisolated static let compressorTypeID = DSPCompressorParameters.typeID
    /// Native effects with typed parameter sets, in add-menu order.
    nonisolated static let nativeEffectTypeIDs: [String] = [
        classicBassTypeID, hybridBassTypeID, stereoWidthTypeID, crossfeedTypeID,
        spatialAudioTypeID, reverbTypeID, tubeTypeID, compressorTypeID,
    ]
    nonisolated static let defaultChannelPolicy = "fullRange"
    nonisolated static let supportedChannelPolicies: Set<String> = ["allChannels", "frontPair", "fullRange"]
    nonisolated static let standardQuality = "standard"
    nonisolated static let oversampling2xQuality = "oversampling2x"
    nonisolated static let oversampling4xQuality = "oversampling4x"

    var nodeID: UUID
    var typeID: String
    var algorithmVersion: Int
    var enabled: Bool
    var channelPolicy: String
    var quality: String
    var parameters: [String: DSPJSONValue]

    nonisolated init(
        nodeID: UUID = UUID(),
        typeID: String,
        algorithmVersion: Int = 1,
        enabled: Bool = true,
        channelPolicy: String = Self.defaultChannelPolicy,
        quality: String = "standard",
        parameters: [String: DSPJSONValue] = [:]
    ) {
        self.nodeID = nodeID
        self.typeID = typeID
        self.algorithmVersion = algorithmVersion
        self.enabled = enabled
        self.channelPolicy = channelPolicy
        self.quality = quality
        self.parameters = parameters
    }

    nonisolated var parametricEQBands: [DSPParametricEQBand]? {
        get {
            guard typeID == Self.parametricEQTypeID,
                  case .array(let values)? = parameters["bands"]
            else { return nil }
            let bands = values.compactMap(Self.decodeBand)
            guard bands.count == values.count,
                  bands.count == DSPParametricEQBand.defaultBands.count else { return nil }
            return bands
        }
        set {
            guard typeID == Self.parametricEQTypeID, let newValue else { return }
            let existingBands: [DSPJSONValue]
            if case .array(let values)? = parameters["bands"] {
                existingBands = values
            } else {
                existingBands = []
            }
            parameters["bands"] = .array(newValue.enumerated().map { pair in
                let index = pair.offset
                let band = pair.element
                var fields: [String: DSPJSONValue]
                if existingBands.indices.contains(index),
                   case .object(let existingFields) = existingBands[index] {
                    fields = existingFields
                } else {
                    fields = [:]
                }
                fields["enabled"] = .bool(band.enabled)
                fields["type"] = .string(band.type.rawValue)
                fields["frequencyHz"] = .number(band.frequencyHz)
                fields["gainDB"] = .number(band.gainDB)
                fields["q"] = .number(band.q)
                return .object(fields)
            })
        }
    }

    nonisolated var stereoWidthParameters: DSPStereoWidthParameters? {
        get { effectParameters(DSPStereoWidthParameters.self) }
        set { if let newValue { setEffectParameters(newValue) } }
    }

    nonisolated var tubeParameters: DSPTubeParameters? {
        get { effectParameters(DSPTubeParameters.self) }
        set { if let newValue { setEffectParameters(newValue) } }
    }

    /// Types whose processing needs an identified left and right pair.
    nonisolated static let frontPairTypeIDs: Set<String> = [stereoWidthTypeID, crossfeedTypeID, spatialAudioTypeID]
    /// Types that run on a front pair or on a whole mono or stereo source.
    nonisolated static let pairOrStereoTypeIDs: Set<String> = [classicBassTypeID, hybridBassTypeID, reverbTypeID]

    nonisolated static func supportedChannelPolicies(forTypeID typeID: String) -> Set<String> {
        switch typeID {
        case parametricEQTypeID, scriptTypeID, tubeTypeID, compressorTypeID:
            ["allChannels", "fullRange"]
        case _ where frontPairTypeIDs.contains(typeID):
            ["frontPair"]
        case _ where pairOrStereoTypeIDs.contains(typeID):
            ["frontPair", "fullRange"]
        default:
            []
        }
    }

    nonisolated static func defaultChannelPolicy(forTypeID typeID: String) -> String {
        frontPairTypeIDs.contains(typeID) ? "frontPair" : defaultChannelPolicy
    }

    /// The channel scope of an effect follows the source rather than a
    /// listener choice. A stored scope the source cannot honour falls back to
    /// the widest scope it can, so an effect never disappears silently.
    nonisolated static func effectiveChannelPolicy(
        forTypeID typeID: String,
        requested: String,
        format: DSPAudioFormat
    ) -> String {
        if frontPairTypeIDs.contains(typeID) { return "frontPair" }
        if pairOrStereoTypeIDs.contains(typeID) {
            if requested == "frontPair", format.frontStereoPair != nil { return "frontPair" }
            if requested == "fullRange", format.isMonoOrStereoLayout { return "fullRange" }
            return format.frontStereoPair != nil ? "frontPair" : "fullRange"
        }
        if requested == "fullRange", format.hasIdentifiedChannelMap { return "fullRange" }
        return "allChannels"
    }

    nonisolated static func supportedQualities(forTypeID typeID: String) -> Set<String> {
        switch typeID {
        case tubeTypeID:
            [oversampling2xQuality, oversampling4xQuality]
        case parametricEQTypeID, scriptTypeID:
            [standardQuality]
        case _ where nativeEffectTypeIDs.contains(typeID):
            [standardQuality]
        default:
            []
        }
    }

    nonisolated static func defaultQuality(forTypeID typeID: String) -> String {
        typeID == tubeTypeID ? oversampling2xQuality : standardQuality
    }

    /// Parameter keys a node type accepts, or nil for types without a fixed set.
    nonisolated static func supportedParameterKeys(forTypeID typeID: String) -> Set<String>? {
        switch typeID {
        case classicBassTypeID: DSPClassicBassParameters.supportedParameterKeys
        case hybridBassTypeID: DSPHybridBassParameters.supportedParameterKeys
        case stereoWidthTypeID: DSPStereoWidthParameters.supportedParameterKeys
        case crossfeedTypeID: DSPCrossfeedParameters.supportedParameterKeys
        case spatialAudioTypeID: DSPSpatialAudioParameters.supportedParameterKeys
        case reverbTypeID: DSPReverbParameters.supportedParameterKeys
        case tubeTypeID: DSPTubeParameters.supportedParameterKeys
        case compressorTypeID: DSPCompressorParameters.supportedParameterKeys
        default: nil
        }
    }

    /// Range problems of a native effect's parameters; nil when they cannot
    /// be read at all.
    nonisolated var nativeParameterIssues: [DSPParameterIssue]? {
        switch typeID {
        case Self.classicBassTypeID: effectParameters(DSPClassicBassParameters.self)?.validationIssues
        case Self.hybridBassTypeID: effectParameters(DSPHybridBassParameters.self)?.validationIssues
        case Self.stereoWidthTypeID: effectParameters(DSPStereoWidthParameters.self)?.validationIssues
        case Self.crossfeedTypeID: effectParameters(DSPCrossfeedParameters.self)?.validationIssues
        case Self.spatialAudioTypeID: effectParameters(DSPSpatialAudioParameters.self)?.validationIssues
        case Self.reverbTypeID: effectParameters(DSPReverbParameters.self)?.validationIssues
        case Self.tubeTypeID: effectParameters(DSPTubeParameters.self)?.validationIssues
        case Self.compressorTypeID: effectParameters(DSPCompressorParameters.self)?.validationIssues
        default: nil
        }
    }

    /// Name of a node type as listeners see it, shared by the rack and
    /// diagnostics.
    nonisolated static func displayTitle(forTypeID typeID: String) -> String {
        switch typeID {
        case parametricEQTypeID: "均衡器"
        case classicBassTypeID: "经典虚拟低音"
        case hybridBassTypeID: "虚拟低音"
        case stereoWidthTypeID: "立体声扩展"
        case crossfeedTypeID: "交叉馈送"
        case spatialAudioTypeID: "空间音频"
        case reverbTypeID: "混响"
        case tubeTypeID: "电子管模拟"
        case compressorTypeID: "动态压缩"
        case scriptTypeID: "可编程脚本"
        default: typeID
        }
    }

    /// True for an enabled node whose tuning follows the routed transducer.
    nonisolated var followsOutputKind: Bool {
        guard enabled else { return false }
        switch typeID {
        case Self.classicBassTypeID:
            return effectParameters(DSPClassicBassParameters.self)?.target == .automatic
        case Self.hybridBassTypeID:
            return effectParameters(DSPHybridBassParameters.self)?.target == .automatic
        default:
            return false
        }
    }

    nonisolated static func parametricEQ(
        nodeID: UUID = UUID(),
        enabled: Bool = true,
        bands: [DSPParametricEQBand] = DSPParametricEQBand.defaultBands
    ) -> DSPNodeConfiguration {
        var node = DSPNodeConfiguration(
            nodeID: nodeID,
            typeID: Self.parametricEQTypeID,
            enabled: enabled
        )
        node.parametricEQBands = bands
        return node
    }

    nonisolated static func stereoWidth(
        nodeID: UUID = UUID(),
        enabled: Bool = true,
        parameters: DSPStereoWidthParameters = DSPStereoWidthParameters(),
        channelPolicy: String = "frontPair"
    ) -> DSPNodeConfiguration {
        var node = DSPNodeConfiguration(
            nodeID: nodeID,
            typeID: Self.stereoWidthTypeID,
            enabled: enabled,
            channelPolicy: channelPolicy,
            quality: Self.standardQuality
        )
        node.stereoWidthParameters = parameters
        return node
    }

    nonisolated static func classicBass(
        nodeID: UUID = UUID(),
        enabled: Bool = true,
        parameters: DSPClassicBassParameters = DSPClassicBassParameters(),
        channelPolicy: String = "fullRange"
    ) -> DSPNodeConfiguration {
        var node = effect(parameters, nodeID: nodeID, enabled: enabled)
        node.channelPolicy = channelPolicy
        return node
    }

    nonisolated static func hybridBass(
        nodeID: UUID = UUID(),
        enabled: Bool = true,
        parameters: DSPHybridBassParameters = DSPHybridBassParameters(),
        channelPolicy: String = "fullRange"
    ) -> DSPNodeConfiguration {
        var node = effect(parameters, nodeID: nodeID, enabled: enabled)
        node.channelPolicy = channelPolicy
        return node
    }

    nonisolated static func tube(
        nodeID: UUID = UUID(),
        enabled: Bool = true,
        parameters: DSPTubeParameters = DSPTubeParameters(),
        channelPolicy: String = "fullRange",
        quality: String = "oversampling2x"
    ) -> DSPNodeConfiguration {
        var node = DSPNodeConfiguration(
            nodeID: nodeID,
            typeID: Self.tubeTypeID,
            enabled: enabled,
            channelPolicy: channelPolicy,
            quality: quality
        )
        node.tubeParameters = parameters
        return node
    }

    nonisolated private static func decodeBand(_ value: DSPJSONValue) -> DSPParametricEQBand? {
        guard case .object(let fields) = value,
              case .bool(let enabled)? = fields["enabled"],
              case .string(let typeID)? = fields["type"],
              let type = DSPFilterType(rawValue: typeID),
              let frequencyHz = fields["frequencyHz"]?.numberValue,
              let gainDB = fields["gainDB"]?.numberValue,
              let q = fields["q"]?.numberValue
        else { return nil }
        return DSPParametricEQBand(
            enabled: enabled,
            type: type,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            q: q
        )
    }

}

/// How much bass and treble the stage adds comes from the preset's
/// calibration (or the fixed default curve); the stage itself only scales it.
nonisolated struct DSPEqualLoudnessParameters: Codable, Equatable, Sendable {
    nonisolated static let strengthRange: ClosedRange<Double> = 0...1
    nonisolated static let bassFrequencyRange: ClosedRange<Double> = 20...500
    nonisolated static let trebleFrequencyRange: ClosedRange<Double> = 1_000...20_000
    nonisolated static let shelfSlopeRange = DSPParametricEQBand.shelfSlopeRange
    /// Shelf gain limits. Volumes louder than the calibration reference may
    /// take a cut, so both directions are allowed.
    nonisolated static let bassGainRange: ClosedRange<Double> = -12...12
    nonisolated static let trebleGainRange: ClosedRange<Double> = -9...9

    var strength: Double
    var bassFrequencyHz: Double
    /// RBJ shelf slope S (0.25...1), retained as `Q` in the schema.
    var bassQ: Double
    var trebleFrequencyHz: Double
    /// RBJ shelf slope S (0.25...1), retained as `Q` in the schema.
    var trebleQ: Double

    nonisolated init(
        strength: Double = 1,
        bassFrequencyHz: Double = 70,
        bassQ: Double = 0.71,
        trebleFrequencyHz: Double = 3_500,
        trebleQ: Double = 0.71
    ) {
        self.strength = strength
        self.bassFrequencyHz = bassFrequencyHz
        self.bassQ = bassQ
        self.trebleFrequencyHz = trebleFrequencyHz
        self.trebleQ = trebleQ
    }
}

/// The fixed equal-loudness stage after the effect nodes and before the
/// output gain. Shelves placed here never change how hard a saturating node
/// is driven as the system volume moves. A preset serves one device, so the
/// stage keeps one calibration; one recorded on another device stays unused.
nonisolated struct DSPEqualLoudnessStage: Codable, Equatable, Sendable {
    /// Identity of the stage inside the processor chain.
    nonisolated static let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    var enabled: Bool
    var parameters: DSPEqualLoudnessParameters
    var calibration: EqualLoudnessCalibration?

    nonisolated init(
        enabled: Bool = false,
        parameters: DSPEqualLoudnessParameters = DSPEqualLoudnessParameters(),
        calibration: EqualLoudnessCalibration? = nil
    ) {
        self.enabled = enabled
        self.parameters = parameters
        self.calibration = calibration
    }

    /// The processor runs the stage as the last linear node of the chain.
    nonisolated var runtimeNode: DSPNodeConfiguration {
        DSPNodeConfiguration(
            nodeID: Self.nodeID,
            typeID: DSPNodeConfiguration.equalLoudnessTypeID,
            enabled: enabled
        )
    }
}

nonisolated struct AudioDSPConfiguration: Codable, Equatable, Sendable {
    nonisolated static let maximumNodeCount = 32
    nonisolated static let flatEQNodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    var enabled: Bool
    var inputTrimDB: Double
    var outputTrimDB: Double
    var headroom: DSPHeadroomConfiguration
    var nodes: [DSPNodeConfiguration]
    var equalLoudness: DSPEqualLoudnessStage
    var limiter: DSPLimiterConfiguration

    private enum CodingKeys: String, CodingKey {
        case enabled, inputTrimDB, outputTrimDB, headroom, nodes, equalLoudness, limiter
    }

    nonisolated init(
        enabled: Bool = false,
        inputTrimDB: Double = 0,
        outputTrimDB: Double = 0,
        headroom: DSPHeadroomConfiguration = DSPHeadroomConfiguration(),
        nodes: [DSPNodeConfiguration] = [.parametricEQ()],
        equalLoudness: DSPEqualLoudnessStage = DSPEqualLoudnessStage(),
        limiter: DSPLimiterConfiguration = DSPLimiterConfiguration()
    ) {
        self.enabled = enabled
        self.inputTrimDB = inputTrimDB
        self.outputTrimDB = outputTrimDB
        self.headroom = headroom
        self.nodes = nodes
        self.equalLoudness = equalLoudness
        self.limiter = limiter
    }

    /// Presets saved before the limiter existed start with it switched on.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        inputTrimDB = try container.decode(Double.self, forKey: .inputTrimDB)
        outputTrimDB = try container.decode(Double.self, forKey: .outputTrimDB)
        headroom = try container.decode(DSPHeadroomConfiguration.self, forKey: .headroom)
        nodes = try container.decode([DSPNodeConfiguration].self, forKey: .nodes)
        equalLoudness = try container.decode(DSPEqualLoudnessStage.self, forKey: .equalLoudness)
        limiter = try container.decodeIfPresent(DSPLimiterConfiguration.self, forKey: .limiter)
            ?? DSPLimiterConfiguration()
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(inputTrimDB, forKey: .inputTrimDB)
        try container.encode(outputTrimDB, forKey: .outputTrimDB)
        try container.encode(headroom, forKey: .headroom)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(equalLoudness, forKey: .equalLoudness)
        try container.encode(limiter, forKey: .limiter)
    }

    /// Everything the processor runs, in signal order: the effect nodes,
    /// then the equal-loudness stage.
    nonisolated var processingNodes: [DSPNodeConfiguration] {
        nodes + [equalLoudness.runtimeNode]
    }

    nonisolated static var defaultFlat: AudioDSPConfiguration {
        AudioDSPConfiguration(
            nodes: [.parametricEQ(nodeID: flatEQNodeID)]
        )
    }

    nonisolated static var defaultEffects: AudioDSPConfiguration {
        AudioDSPConfiguration(nodes: [
            .parametricEQ(nodeID: flatEQNodeID),
            .effect(DSPHybridBassParameters(),
                    nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, enabled: false),
            .stereoWidth(nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!),
            .effect(DSPCrossfeedParameters(),
                    nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, enabled: false),
            .effect(DSPReverbParameters(),
                    nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!, enabled: false),
            .tube(nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!),
        ])
    }

    /// Everything that changes the processing topology: node set and order,
    /// quality, channel scope, EQ band types and script source. Two
    /// configurations with the same signature differ only in values (gains,
    /// frequencies, mixes, trims, node and chain switches), which the renderer
    /// applies through its parameter channel without flushing queued audio.
    nonisolated var structureSignature: [String] {
        nodes.map { node in
            var parts = [
                node.nodeID.uuidString, node.typeID, String(node.algorithmVersion),
                node.quality, node.channelPolicy,
            ]
            switch node.typeID {
            case DSPNodeConfiguration.parametricEQTypeID:
                parts += (node.parametricEQBands ?? []).map(\.type.rawValue)
            case DSPNodeConfiguration.scriptTypeID:
                if let script = node.scriptParameters {
                    parts += [String(script.languageVersion), script.source]
                }
            default:
                break
            }
            return parts.joined(separator: "|")
        }
    }

    nonisolated func hasSameStructure(as other: AudioDSPConfiguration) -> Bool {
        structureSignature == other.structureSignature
    }

    /// True when an active effect retunes itself for headphones or speakers.
    nonisolated var followsOutputKind: Bool {
        enabled && nodes.contains(where: \.followsOutputKind)
    }

    /// True when an active effect renders its own spatial image, which the
    /// system's spatialization must not process again.
    nonisolated var rendersSpatialImage: Bool {
        enabled && nodes.contains { $0.enabled && $0.typeID == DSPNodeConfiguration.spatialAudioTypeID }
    }
}

nonisolated struct DSPAudioFormat: Codable, Equatable, Sendable {
    var sampleRate: Double
    var channelCount: Int
    var rawLayoutData: Data?
    var channelLabels: [UInt32]?
    var layoutIsKnown: Bool
}

nonisolated extension DSPAudioFormat {
    nonisolated static let lowFrequencyEffectLabels: Set<UInt32> = [
        UInt32(kAudioChannelLabel_LFEScreen),
        UInt32(kAudioChannelLabel_LFE2),
        UInt32(kAudioChannelLabel_LFE3),
    ]

    /// Speaker roles require a complete, identified channel map. A channel
    /// count alone never establishes which channel is which.
    var hasIdentifiedChannelMap: Bool {
        layoutIsKnown && channelLabels?.count == channelCount
    }

    /// The single identifiable left and right channel, when the source
    /// carries them.
    var frontStereoPair: (left: Int, right: Int)? {
        guard hasIdentifiedChannelMap, let labels = channelLabels else { return nil }
        let left = labels.indices.filter { labels[$0] == UInt32(kAudioChannelLabel_Left) }
        let right = labels.indices.filter { labels[$0] == UInt32(kAudioChannelLabel_Right) }
        guard left.count == 1, right.count == 1 else { return nil }
        return (left[0], right[0])
    }

    /// True for a known mono or stereo layout.
    var isMonoOrStereoLayout: Bool {
        guard hasIdentifiedChannelMap, let labels = channelLabels, channelCount <= 2 else {
            return false
        }
        if channelCount == 1 { return labels[0] == UInt32(kAudioChannelLabel_Mono) }
        return Set(labels) == Set([UInt32(kAudioChannelLabel_Left), UInt32(kAudioChannelLabel_Right)])
    }

    /// True for every channel that is not a low-frequency effects channel, or
    /// nil when the source has no channel map to identify one.
    var fullRangeChannelMask: [Bool]? {
        guard hasIdentifiedChannelMap, let labels = channelLabels else { return nil }
        return labels.map { !Self.lowFrequencyEffectLabels.contains($0) }
    }
}

/// Audio transport fade. Only the switch is a user setting;
/// play fade duration (320 ms), pause fade duration (700 ms),
/// floor dB (−40 dB), and curve (perceptualDB) are fixed.
nonisolated struct AudioFadeConfiguration: Codable, Equatable, Sendable {
    nonisolated static let fixedPlayFadeMs = 320.0
    nonisolated static let fixedPauseFadeMs = 700.0
    nonisolated static let fixedFloorDB = -40.0
    nonisolated static let fixedCurve = "perceptualDB"

    var enabled: Bool

    nonisolated var playFadeMs: Double { Self.fixedPlayFadeMs }
    nonisolated var pauseFadeMs: Double { Self.fixedPauseFadeMs }
    nonisolated var floorDB: Double { Self.fixedFloorDB }
    nonisolated var curve: String { Self.fixedCurve }

    nonisolated init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

/// Volume normalization. Only the switch and the target are user settings;
/// the boost, attenuation and true-peak limits are fixed. Album handling is
/// decided per album (automatic judgement plus a per-album override).
nonisolated struct AudioLoudnessConfiguration: Codable, Equatable, Sendable {
    nonisolated static let targetRange: ClosedRange<Double> = -20 ... -8
    nonisolated static let defaultTargetLUFS = -14.0
    nonisolated static let fixedMaxBoostDB = 12.0
    nonisolated static let fixedMaxAttenuationDB = 24.0
    nonisolated static let fixedTruePeakCeilingDBTP = -1.0

    var enabled: Bool
    var targetLUFS: Double

    nonisolated var maxBoostDB: Double { Self.fixedMaxBoostDB }
    nonisolated var maxAttenuationDB: Double { Self.fixedMaxAttenuationDB }
    nonisolated var truePeakCeilingDBTP: Double { Self.fixedTruePeakCeilingDBTP }

    nonisolated init(enabled: Bool = false, targetLUFS: Double = Self.defaultTargetLUFS) {
        self.enabled = enabled
        self.targetLUFS = targetLUFS
    }
}

nonisolated struct AudioProcessingGlobals: Codable, Equatable, Sendable {
    var fade: AudioFadeConfiguration
    var loudness: AudioLoudnessConfiguration

    nonisolated init(
        fade: AudioFadeConfiguration = AudioFadeConfiguration(),
        loudness: AudioLoudnessConfiguration = AudioLoudnessConfiguration()
    ) {
        self.fade = fade
        self.loudness = loudness
    }
}

nonisolated struct AudioProcessingRuntimeState: Codable, Equatable, Sendable {
    var transport: AudioTransportTransitionState?
    var outputDeviceUID: String?

    nonisolated init(
        transport: AudioTransportTransitionState? = nil,
        outputDeviceUID: String? = nil
    ) {
        self.transport = transport
        self.outputDeviceUID = outputDeviceUID
    }
}

nonisolated struct DSPDiagnostic: Codable, Equatable, Sendable, Identifiable {
    var code: String
    var message: String
    var fieldPath: String?
    var nodeID: UUID?
    var retryable: Bool
    var line: Int?
    var column: Int?

    nonisolated var id: String {
        ([code, fieldPath ?? "", nodeID?.uuidString ?? ""]
            + [line, column].compactMap { $0.map(String.init) }).joined(separator: "|")
    }

    nonisolated init(
        code: String,
        message: String,
        fieldPath: String? = nil,
        nodeID: UUID? = nil,
        retryable: Bool = false,
        line: Int? = nil,
        column: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.fieldPath = fieldPath
        self.nodeID = nodeID
        self.retryable = retryable
        self.line = line
        self.column = column
    }
}

nonisolated enum DSPApplyState: String, Codable, Equatable, Sendable {
    case ready
    case preparing
    case scheduled
    case audible
    case superseded
    case failed
    case inactiveExternalSource
}

nonisolated struct DSPApplyStatus: Codable, Equatable, Sendable {
    var requestID: UUID?
    var revisionString: String
    var state: DSPApplyState
    var format: DSPAudioFormat?
    var scheduledPTS: Double?
    var audiblePTS: Double?
    var headroomDB: Double?
    var processingLatencyFrames: Int?
    var mediaMappingLatencyFrames: Int?
    var peakGuarantee: String?
    var warnings: [DSPDiagnostic]
    var diagnostics: [DSPDiagnostic]
    var rebuffered: Bool

    nonisolated init(
        requestID: UUID? = nil,
        revisionString: String,
        state: DSPApplyState = .ready,
        format: DSPAudioFormat? = nil,
        scheduledPTS: Double? = nil,
        audiblePTS: Double? = nil,
        headroomDB: Double? = nil,
        processingLatencyFrames: Int? = nil,
        mediaMappingLatencyFrames: Int? = nil,
        peakGuarantee: String? = nil,
        warnings: [DSPDiagnostic] = [],
        diagnostics: [DSPDiagnostic] = [],
        rebuffered: Bool = false
    ) {
        self.requestID = requestID
        self.revisionString = revisionString
        self.state = state
        self.format = format
        self.scheduledPTS = scheduledPTS
        self.audiblePTS = audiblePTS
        self.headroomDB = headroomDB
        self.processingLatencyFrames = processingLatencyFrames
        self.mediaMappingLatencyFrames = mediaMappingLatencyFrames
        self.peakGuarantee = peakGuarantee
        self.warnings = warnings
        self.diagnostics = diagnostics
        self.rebuffered = rebuffered
    }
}

nonisolated struct DSPApplyEvent: Codable, Equatable, Sendable {
    var requestID: UUID
    var revisionString: String
    var state: DSPApplyState
    var format: DSPAudioFormat?
    var scheduledPTS: Double?
    var audiblePTS: Double?
    var headroomDB: Double?
    var processingLatencyFrames: Int?
    var mediaMappingLatencyFrames: Int?
    var peakGuarantee: String?
    var warnings: [DSPDiagnostic]
    var diagnostics: [DSPDiagnostic]
    var rebuffered: Bool

    nonisolated init(
        requestID: UUID,
        revisionString: String,
        state: DSPApplyState,
        format: DSPAudioFormat? = nil,
        scheduledPTS: Double? = nil,
        audiblePTS: Double? = nil,
        headroomDB: Double? = nil,
        processingLatencyFrames: Int? = nil,
        mediaMappingLatencyFrames: Int? = nil,
        peakGuarantee: String? = nil,
        warnings: [DSPDiagnostic] = [],
        diagnostics: [DSPDiagnostic] = [],
        rebuffered: Bool = false
    ) {
        self.requestID = requestID
        self.revisionString = revisionString
        self.state = state
        self.format = format
        self.scheduledPTS = scheduledPTS
        self.audiblePTS = audiblePTS
        self.headroomDB = headroomDB
        self.processingLatencyFrames = processingLatencyFrames
        self.mediaMappingLatencyFrames = mediaMappingLatencyFrames
        self.peakGuarantee = peakGuarantee
        self.warnings = warnings
        self.diagnostics = diagnostics
        self.rebuffered = rebuffered
    }

    nonisolated var status: DSPApplyStatus {
        DSPApplyStatus(
            requestID: requestID,
            revisionString: revisionString,
            state: state,
            format: format,
            scheduledPTS: scheduledPTS,
            audiblePTS: audiblePTS,
            headroomDB: headroomDB,
            processingLatencyFrames: processingLatencyFrames,
            mediaMappingLatencyFrames: mediaMappingLatencyFrames,
            peakGuarantee: peakGuarantee,
            warnings: warnings,
            diagnostics: diagnostics,
            rebuffered: rebuffered
        )
    }
}

nonisolated struct DSPPresetDocument: Codable, Equatable, Sendable, Identifiable {
    nonisolated static let schemaVersion = 2
    nonisolated static let flatPresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    nonisolated static let defaultPresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    var schemaVersion: Int
    var presetID: UUID
    var name: String
    var revisionString: String
    var configuration: AudioDSPConfiguration

    nonisolated var id: UUID { presetID }
    nonisolated var isBuiltIn: Bool { Self.isBuiltIn(presetID) }

    nonisolated static func isBuiltIn(_ id: UUID) -> Bool {
        id == flatPresetID || id == defaultPresetID
    }

    nonisolated static var builtInPresets: [DSPPresetDocument] { [.defaultEffects, .flat] }

    nonisolated static var defaultEffects: DSPPresetDocument {
        DSPPresetDocument(
            schemaVersion: schemaVersion,
            presetID: defaultPresetID,
            name: "默认",
            revisionString: "builtin-default-v1",
            configuration: .defaultEffects
        )
    }

    nonisolated static var flat: DSPPresetDocument {
        DSPPresetDocument(
            schemaVersion: schemaVersion,
            presetID: flatPresetID,
            name: "平直",
            revisionString: "builtin-flat-v1",
            configuration: .defaultFlat
        )
    }

    nonisolated init(
        schemaVersion: Int = Self.schemaVersion,
        presetID: UUID = UUID(),
        name: String,
        revisionString: String = UUID().uuidString,
        configuration: AudioDSPConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.presetID = presetID
        self.name = name
        self.revisionString = revisionString
        self.configuration = configuration
    }
}

nonisolated struct DSPPresetImportPreview: Codable, Equatable, Sendable {
    var document: DSPPresetDocument
    var isCompatible: Bool
    var canImport: Bool
    var warnings: [DSPDiagnostic]
    var diagnostics: [DSPDiagnostic]

    nonisolated init(document: DSPPresetDocument, isCompatible: Bool, canImport: Bool? = nil,
                     warnings: [DSPDiagnostic], diagnostics: [DSPDiagnostic]) {
        self.document = document
        self.isCompatible = isCompatible
        self.canImport = canImport ?? isCompatible
        self.warnings = warnings
        self.diagnostics = diagnostics
    }

    nonisolated var summary: String {
        if let first = diagnostics.first {
            return first.message
        }
        if let first = warnings.first {
            return first.message
        }
        return "预设可导入。"
    }
}
