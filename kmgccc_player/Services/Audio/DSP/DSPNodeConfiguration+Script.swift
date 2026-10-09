import Foundation

nonisolated struct DSPScriptNodeParameters: Codable, Equatable, Sendable {
    static let supportedParameterKeys: Set<String> = ["languageVersion", "source", "values"]
    static let defaultSource = """
    param gainDB(-24, 12) = 0;
    prepare { let gain = dbToGain(gainDB); }
    process { output = input * gain; }
    """

    var languageVersion: Int
    var source: String
    var values: [String: Double]

    init(languageVersion: Int = 1, source: String = Self.defaultSource, values: [String: Double] = [:]) {
        self.languageVersion = languageVersion
        self.source = source
        self.values = values
    }
}

nonisolated extension DSPNodeConfiguration {
    static let scriptTypeID = "script"

    var scriptParameters: DSPScriptNodeParameters? {
        get {
            guard typeID == Self.scriptTypeID,
                  let version = parameters["languageVersion"]?.numberValue,
                  let languageVersion = Int(exactly: version),
                  case .string(let source)? = parameters["source"],
                  case .object(let fields)? = parameters["values"] else { return nil }
            var values = [String: Double]()
            for (key, value) in fields {
                guard let number = value.numberValue else { return nil }
                values[key] = number
            }
            return DSPScriptNodeParameters(languageVersion: languageVersion, source: source, values: values)
        }
        set {
            guard typeID == Self.scriptTypeID, let value = newValue else { return }
            parameters["languageVersion"] = .integer(Int64(value.languageVersion))
            parameters["source"] = .string(value.source)
            parameters["values"] = .object(value.values.mapValues(DSPJSONValue.number))
        }
    }

    static func script(nodeID: UUID = UUID(), enabled: Bool = true,
                       parameters: DSPScriptNodeParameters = DSPScriptNodeParameters()) -> Self {
        var node = Self(nodeID: nodeID, typeID: scriptTypeID, enabled: enabled)
        node.scriptParameters = parameters
        return node
    }
}
