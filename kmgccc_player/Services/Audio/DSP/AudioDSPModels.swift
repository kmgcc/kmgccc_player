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
    nonisolated static let defaultChannelPolicy = "fullRange"
    nonisolated static let supportedChannelPolicies: Set<String> = ["allChannels", "fullRange"]

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

nonisolated struct DSPDiagnostic: Codable, Equatable, Sendable, Identifiable {
    var code: String
    var message: String
    var fieldPath: String?
    var nodeID: UUID?
    var retryable: Bool

    nonisolated var id: String {
        [code, fieldPath ?? "", nodeID?.uuidString ?? ""].joined(separator: "|")
    }

    nonisolated init(
        code: String,
        message: String,
        fieldPath: String? = nil,
        nodeID: UUID? = nil,
        retryable: Bool = false
    ) {
        self.code = code
        self.message = message
        self.fieldPath = fieldPath
        self.nodeID = nodeID
        self.retryable = retryable
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
    var warnings: [DSPDiagnostic]
    var diagnostics: [DSPDiagnostic]
    var rebuffered: Bool

    nonisolated var status: DSPApplyStatus {
        DSPApplyStatus(
            requestID: requestID,
            revisionString: revisionString,
            state: state,
            format: format,
            scheduledPTS: scheduledPTS,
            audiblePTS: audiblePTS,
            headroomDB: headroomDB,
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
