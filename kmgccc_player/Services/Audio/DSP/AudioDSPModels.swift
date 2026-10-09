//
//  AudioDSPModels.swift
//  myPlayer2
//
//  Value types shared by the DSP controller, preset store, and renderer.
//

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

nonisolated struct DSPHeadroomConfiguration: Codable, Equatable, Sendable {
    var mode: DSPHeadroomMode
    var marginDB: Double

    nonisolated init(mode: DSPHeadroomMode = .automatic, marginDB: Double = 2) {
        self.mode = mode
        self.marginDB = marginDB
    }
}

nonisolated struct DSPNodeConfiguration: Codable, Equatable, Sendable {
    nonisolated static let parametricEQTypeID = "peq9"
    nonisolated static let equalLoudnessTypeID = "equalLoudness"
    nonisolated static let stereoWidthTypeID = "stereoWidth"
    nonisolated static let virtualBassTypeID = "virtualBass"
    nonisolated static let tubeTypeID = "tube"
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
            guard bands.count == values.count, bands.count == 9 else { return nil }
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

    nonisolated var equalLoudnessParameters: DSPEqualLoudnessParameters? {
        get {
            guard typeID == Self.equalLoudnessTypeID,
                  let strength = parameters["strength"]?.numberValue,
                  let maxBassGainDB = parameters["maxBassGainDB"]?.numberValue,
                  let maxTrebleGainDB = parameters["maxTrebleGainDB"]?.numberValue,
                  let bassFrequencyHz = parameters["bassFrequencyHz"]?.numberValue,
                  let bassQ = parameters["bassQ"]?.numberValue,
                  let trebleFrequencyHz = parameters["trebleFrequencyHz"]?.numberValue,
                  let trebleQ = parameters["trebleQ"]?.numberValue,
                  let compensationWindowDB = parameters["compensationWindowDB"]?.numberValue,
                  case .string(let rawHeadroomMode)? = parameters["headroomMode"],
                  let headroomMode = DSPHeadroomMode(rawValue: rawHeadroomMode)
            else { return nil }
            return DSPEqualLoudnessParameters(
                strength: strength,
                maxBassGainDB: maxBassGainDB,
                maxTrebleGainDB: maxTrebleGainDB,
                bassFrequencyHz: bassFrequencyHz,
                bassQ: bassQ,
                trebleFrequencyHz: trebleFrequencyHz,
                trebleQ: trebleQ,
                compensationWindowDB: compensationWindowDB,
                headroomMode: headroomMode
            )
        }
        set {
            guard typeID == Self.equalLoudnessTypeID, let newValue else { return }
            parameters["strength"] = .number(newValue.strength)
            parameters["maxBassGainDB"] = .number(newValue.maxBassGainDB)
            parameters["maxTrebleGainDB"] = .number(newValue.maxTrebleGainDB)
            parameters["bassFrequencyHz"] = .number(newValue.bassFrequencyHz)
            parameters["bassQ"] = .number(newValue.bassQ)
            parameters["trebleFrequencyHz"] = .number(newValue.trebleFrequencyHz)
            parameters["trebleQ"] = .number(newValue.trebleQ)
            parameters["compensationWindowDB"] = .number(newValue.compensationWindowDB)
            parameters["headroomMode"] = .string(newValue.headroomMode.rawValue)
        }
    }

    nonisolated var stereoWidthParameters: DSPStereoWidthParameters? {
        get {
            guard typeID == Self.stereoWidthTypeID,
                  let width = parameters["width"]?.numberValue,
                  let outputTrimDB = parameters["outputTrimDB"]?.numberValue else { return nil }
            return DSPStereoWidthParameters(width: width, outputTrimDB: outputTrimDB)
        }
        set {
            guard typeID == Self.stereoWidthTypeID, let newValue else { return }
            parameters["width"] = .number(newValue.width)
            parameters["outputTrimDB"] = .number(newValue.outputTrimDB)
        }
    }

    nonisolated var virtualBassParameters: DSPVirtualBassParameters? {
        get {
            guard typeID == Self.virtualBassTypeID,
                  let lowFrequencyHz = parameters["lowFrequencyHz"]?.numberValue,
                  let highFrequencyHz = parameters["highFrequencyHz"]?.numberValue,
                  let amount = parameters["amount"]?.numberValue,
                  let driveDB = parameters["driveDB"]?.numberValue,
                  let harmonics = parameters["harmonics"]?.numberValue,
                  let mix = parameters["mix"]?.numberValue,
                  let outputTrimDB = parameters["outputTrimDB"]?.numberValue else { return nil }
            return DSPVirtualBassParameters(
                lowFrequencyHz: lowFrequencyHz,
                highFrequencyHz: highFrequencyHz,
                amount: amount,
                driveDB: driveDB,
                harmonics: harmonics,
                mix: mix,
                outputTrimDB: outputTrimDB
            )
        }
        set {
            guard typeID == Self.virtualBassTypeID, let newValue else { return }
            parameters["lowFrequencyHz"] = .number(newValue.lowFrequencyHz)
            parameters["highFrequencyHz"] = .number(newValue.highFrequencyHz)
            parameters["amount"] = .number(newValue.amount)
            parameters["driveDB"] = .number(newValue.driveDB)
            parameters["harmonics"] = .number(newValue.harmonics)
            parameters["mix"] = .number(newValue.mix)
            parameters["outputTrimDB"] = .number(newValue.outputTrimDB)
        }
    }

    nonisolated var tubeParameters: DSPTubeParameters? {
        get {
            guard typeID == Self.tubeTypeID,
                  let driveDB = parameters["driveDB"]?.numberValue,
                  let bias = parameters["bias"]?.numberValue,
                  let mix = parameters["mix"]?.numberValue,
                  let inputTrimDB = parameters["inputTrimDB"]?.numberValue,
                  let outputTrimDB = parameters["outputTrimDB"]?.numberValue,
                  case .bool(let dcRemovalEnabled)? = parameters["dcRemovalEnabled"],
                  let dcBlockHz = parameters["dcBlockHz"]?.numberValue else { return nil }
            return DSPTubeParameters(
                driveDB: driveDB,
                bias: bias,
                mix: mix,
                inputTrimDB: inputTrimDB,
                outputTrimDB: outputTrimDB,
                dcRemovalEnabled: dcRemovalEnabled,
                dcBlockHz: dcBlockHz
            )
        }
        set {
            guard typeID == Self.tubeTypeID, let newValue else { return }
            parameters["driveDB"] = .number(newValue.driveDB)
            parameters["bias"] = .number(newValue.bias)
            parameters["mix"] = .number(newValue.mix)
            parameters["inputTrimDB"] = .number(newValue.inputTrimDB)
            parameters["outputTrimDB"] = .number(newValue.outputTrimDB)
            parameters["dcRemovalEnabled"] = .bool(newValue.dcRemovalEnabled)
            parameters["dcBlockHz"] = .number(newValue.dcBlockHz)
        }
    }

    nonisolated static func supportedChannelPolicies(forTypeID typeID: String) -> Set<String> {
        switch typeID {
        case parametricEQTypeID, equalLoudnessTypeID, scriptTypeID:
            ["allChannels", "fullRange"]
        case stereoWidthTypeID:
            ["frontPair"]
        case virtualBassTypeID:
            ["frontPair", "fullRange"]
        case tubeTypeID:
            ["allChannels", "fullRange"]
        default:
            []
        }
    }

    nonisolated static func defaultChannelPolicy(forTypeID typeID: String) -> String {
        typeID == stereoWidthTypeID ? "frontPair" : defaultChannelPolicy
    }

    nonisolated static func supportedQualities(forTypeID typeID: String) -> Set<String> {
        switch typeID {
        case parametricEQTypeID, equalLoudnessTypeID, stereoWidthTypeID, scriptTypeID:
            [standardQuality]
        case virtualBassTypeID, tubeTypeID:
            [oversampling2xQuality, oversampling4xQuality]
        default:
            []
        }
    }

    nonisolated static func defaultQuality(forTypeID typeID: String) -> String {
        switch typeID {
        case virtualBassTypeID, tubeTypeID:
            oversampling2xQuality
        default:
            standardQuality
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

    nonisolated static func equalLoudness(
        nodeID: UUID = UUID(),
        enabled: Bool = true,
        parameters: DSPEqualLoudnessParameters = DSPEqualLoudnessParameters()
    ) -> DSPNodeConfiguration {
        var node = DSPNodeConfiguration(
            nodeID: nodeID,
            typeID: Self.equalLoudnessTypeID,
            enabled: enabled
        )
        node.equalLoudnessParameters = parameters
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

    nonisolated static func virtualBass(
        nodeID: UUID = UUID(),
        enabled: Bool = true,
        parameters: DSPVirtualBassParameters = DSPVirtualBassParameters(),
        channelPolicy: String = "fullRange",
        quality: String = "oversampling2x"
    ) -> DSPNodeConfiguration {
        var node = DSPNodeConfiguration(
            nodeID: nodeID,
            typeID: Self.virtualBassTypeID,
            enabled: enabled,
            channelPolicy: channelPolicy,
            quality: quality
        )
        node.virtualBassParameters = parameters
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

nonisolated struct DSPStereoWidthParameters: Codable, Equatable, Sendable {
    nonisolated static let widthRange: ClosedRange<Double> = 0...2
    nonisolated static let outputTrimRange: ClosedRange<Double> = -24...6
    nonisolated static let supportedParameterKeys: Set<String> = ["width", "outputTrimDB"]

    var width: Double
    var outputTrimDB: Double

    nonisolated init(width: Double = 1, outputTrimDB: Double = 0) {
        self.width = width
        self.outputTrimDB = outputTrimDB
    }
}

nonisolated struct DSPVirtualBassParameters: Codable, Equatable, Sendable {
    nonisolated static let lowFrequencyRange: ClosedRange<Double> = 20...180
    nonisolated static let highFrequencyRange: ClosedRange<Double> = 40...300
    nonisolated static let amountRange: ClosedRange<Double> = 0...1
    nonisolated static let driveRange: ClosedRange<Double> = 0...18
    nonisolated static let harmonicsRange: ClosedRange<Double> = 0...1
    nonisolated static let mixRange: ClosedRange<Double> = 0...1
    nonisolated static let outputTrimRange: ClosedRange<Double> = -24...6
    nonisolated static let supportedParameterKeys: Set<String> = [
        "lowFrequencyHz", "highFrequencyHz", "amount", "driveDB", "harmonics", "mix", "outputTrimDB",
    ]

    var lowFrequencyHz: Double
    var highFrequencyHz: Double
    var amount: Double
    var driveDB: Double
    var harmonics: Double
    var mix: Double
    var outputTrimDB: Double

    nonisolated init(
        lowFrequencyHz: Double = 40,
        highFrequencyHz: Double = 120,
        amount: Double = 0.5,
        driveDB: Double = 6,
        harmonics: Double = 0.5,
        mix: Double = 0,
        outputTrimDB: Double = 0
    ) {
        self.lowFrequencyHz = lowFrequencyHz
        self.highFrequencyHz = highFrequencyHz
        self.amount = amount
        self.driveDB = driveDB
        self.harmonics = harmonics
        self.mix = mix
        self.outputTrimDB = outputTrimDB
    }
}

nonisolated struct DSPTubeParameters: Codable, Equatable, Sendable {
    nonisolated static let driveRange: ClosedRange<Double> = 0...18
    nonisolated static let biasRange: ClosedRange<Double> = -0.5...0.5
    nonisolated static let mixRange: ClosedRange<Double> = 0...1
    nonisolated static let inputTrimRange: ClosedRange<Double> = -24...12
    nonisolated static let outputTrimRange: ClosedRange<Double> = -24...6
    nonisolated static let dcBlockFrequencyRange: ClosedRange<Double> = 5...40
    nonisolated static let supportedParameterKeys: Set<String> = [
        "driveDB", "bias", "mix", "inputTrimDB", "outputTrimDB",
        "dcRemovalEnabled", "dcBlockHz",
    ]

    var driveDB: Double
    var bias: Double
    var mix: Double
    var inputTrimDB: Double
    var outputTrimDB: Double
    var dcRemovalEnabled: Bool
    var dcBlockHz: Double

    nonisolated init(
        driveDB: Double = 6,
        bias: Double = 0.15,
        mix: Double = 0,
        inputTrimDB: Double = 0,
        outputTrimDB: Double = 0,
        dcRemovalEnabled: Bool = true,
        dcBlockHz: Double = 10
    ) {
        self.driveDB = driveDB
        self.bias = bias
        self.mix = mix
        self.inputTrimDB = inputTrimDB
        self.outputTrimDB = outputTrimDB
        self.dcRemovalEnabled = dcRemovalEnabled
        self.dcBlockHz = dcBlockHz
    }
}

nonisolated struct DSPEqualLoudnessParameters: Codable, Equatable, Sendable {
    nonisolated static let strengthRange: ClosedRange<Double> = 0...1
    nonisolated static let bassFrequencyRange: ClosedRange<Double> = 20...500
    nonisolated static let trebleFrequencyRange: ClosedRange<Double> = 1_000...20_000
    nonisolated static let shelfSlopeRange = DSPParametricEQBand.shelfSlopeRange
    nonisolated static let compensationWindowRange: ClosedRange<Double> = 1...60
    nonisolated static let maxBassGainRange: ClosedRange<Double> = 0...12
    nonisolated static let maxTrebleGainRange: ClosedRange<Double> = 0...6
    nonisolated static let supportedParameterKeys: Set<String> = [
        "strength",
        "maxBassGainDB",
        "maxTrebleGainDB",
        "bassFrequencyHz",
        "bassQ",
        "trebleFrequencyHz",
        "trebleQ",
        "compensationWindowDB",
        "headroomMode",
    ]

    var strength: Double
    var maxBassGainDB: Double
    var maxTrebleGainDB: Double
    var bassFrequencyHz: Double
    /// RBJ shelf slope S (0.25...1), retained as `Q` in the node schema.
    var bassQ: Double
    var trebleFrequencyHz: Double
    /// RBJ shelf slope S (0.25...1), retained as `Q` in the node schema.
    var trebleQ: Double
    var compensationWindowDB: Double
    var headroomMode: DSPHeadroomMode

    nonisolated init(
        strength: Double = 1,
        maxBassGainDB: Double = 6,
        maxTrebleGainDB: Double = 3,
        bassFrequencyHz: Double = 70,
        bassQ: Double = 0.71,
        trebleFrequencyHz: Double = 3_500,
        trebleQ: Double = 0.71,
        compensationWindowDB: Double = 20,
        headroomMode: DSPHeadroomMode = .automatic
    ) {
        self.strength = strength
        self.maxBassGainDB = maxBassGainDB
        self.maxTrebleGainDB = maxTrebleGainDB
        self.bassFrequencyHz = bassFrequencyHz
        self.bassQ = bassQ
        self.trebleFrequencyHz = trebleFrequencyHz
        self.trebleQ = trebleQ
        self.compensationWindowDB = compensationWindowDB
        self.headroomMode = headroomMode
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

    nonisolated init(
        enabled: Bool = false,
        inputTrimDB: Double = 0,
        outputTrimDB: Double = 0,
        headroom: DSPHeadroomConfiguration = DSPHeadroomConfiguration(),
        nodes: [DSPNodeConfiguration] = [.parametricEQ()]
    ) {
        self.enabled = enabled
        self.inputTrimDB = inputTrimDB
        self.outputTrimDB = outputTrimDB
        self.headroom = headroom
        self.nodes = nodes
    }

    nonisolated static var defaultFlat: AudioDSPConfiguration {
        AudioDSPConfiguration(
            nodes: [.parametricEQ(nodeID: flatEQNodeID)]
        )
    }
}

nonisolated struct DSPAudioFormat: Codable, Equatable, Sendable {
    var sampleRate: Double
    var channelCount: Int
    var rawLayoutData: Data?
    var channelLabels: [UInt32]?
    var layoutIsKnown: Bool
}

nonisolated struct AudioFadeConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var playFadeMs: Double
    var pauseFadeMs: Double
    var curve: String
    var floorDB: Double

    nonisolated init(
        enabled: Bool = false,
        playFadeMs: Double = 100,
        pauseFadeMs: Double = 120,
        curve: String = "perceptualDB",
        floorDB: Double = -80
    ) {
        self.enabled = enabled
        self.playFadeMs = playFadeMs
        self.pauseFadeMs = pauseFadeMs
        self.curve = curve
        self.floorDB = floorDB
    }
}

nonisolated struct AudioLoudnessConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var mode: String
    var targetLUFS: Double
    var maxBoostDB: Double
    var maxAttenuationDB: Double
    var truePeakCeilingDBTP: Double
    var missingPolicy: String
    var allowBackgroundScan: Bool

    nonisolated init(
        enabled: Bool = false,
        mode: String = "auto",
        targetLUFS: Double = -18,
        maxBoostDB: Double = 12,
        maxAttenuationDB: Double = 24,
        truePeakCeilingDBTP: Double = -1,
        missingPolicy: String = "unity",
        allowBackgroundScan: Bool = true
    ) {
        self.enabled = enabled
        self.mode = mode
        self.targetLUFS = targetLUFS
        self.maxBoostDB = maxBoostDB
        self.maxAttenuationDB = maxAttenuationDB
        self.truePeakCeilingDBTP = truePeakCeilingDBTP
        self.missingPolicy = missingPolicy
        self.allowBackgroundScan = allowBackgroundScan
    }
}

nonisolated struct AudioProcessingGlobals: Codable, Equatable, Sendable {
    var fade: AudioFadeConfiguration
    var loudness: AudioLoudnessConfiguration
    var deviceReferences: [String: Double]

    nonisolated init(
        fade: AudioFadeConfiguration = AudioFadeConfiguration(),
        loudness: AudioLoudnessConfiguration = AudioLoudnessConfiguration(),
        deviceReferences: [String: Double] = [:]
    ) {
        self.fade = fade
        self.loudness = loudness
        self.deviceReferences = deviceReferences
    }
}

nonisolated struct AudioProcessingRuntimeState: Codable, Equatable, Sendable {
    var transport: AudioTransportTransitionState?
    var outputDeviceUID: String?
    var appGain: Double
    var volumeSource: String
    var referenceDB: Double?

    nonisolated init(
        transport: AudioTransportTransitionState? = nil,
        outputDeviceUID: String? = nil,
        appGain: Double = 1,
        volumeSource: String = "appOnly",
        referenceDB: Double? = nil
    ) {
        self.transport = transport
        self.outputDeviceUID = outputDeviceUID
        self.appGain = appGain
        self.volumeSource = volumeSource
        self.referenceDB = referenceDB
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
    nonisolated static let schemaVersion = 1
    nonisolated static let flatPresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var schemaVersion: Int
    var presetID: UUID
    var name: String
    var revisionString: String
    var configuration: AudioDSPConfiguration

    nonisolated var id: UUID { presetID }
    nonisolated var isBuiltIn: Bool { presetID == Self.flatPresetID }

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
