import Foundation

public extension AutomationMethod {
    static let dspSchema = "dsp.schema"
    static let dspState = "dsp.state"
    static let dspValidate = "dsp.validate"
    static let dspPatch = "dsp.patch"
    static let dspWait = "dsp.wait"
    static let dspPresetsList = "dsp.presets.list"
    static let dspPresetsGet = "dsp.presets.get"
    static let dspPresetsSave = "dsp.presets.save"
    static let dspPresetsSelect = "dsp.presets.select"
    static let dspPresetsRename = "dsp.presets.rename"
    static let dspPresetsDelete = "dsp.presets.delete"
    static let dspPresetsDuplicate = "dsp.presets.duplicate"
    static let dspPresetsImport = "dsp.presets.import"
    static let dspPresetsExport = "dsp.presets.export"
    static let dspErrorsGet = "dsp.errors.get"
    static let dspErrorsClear = "dsp.errors.clear"
}

/// Wire schemas contain no App runtime types. UI and transports still delegate
/// validation, persistence and audio application to the App's DSP controller.
public enum AutomationDSPToolCatalog {
    private static let string: AutomationJSONValue = .object(["type": .string("string")])
    private static let boolean: AutomationJSONValue = .object(["type": .string("boolean")])
    private static let uuid: AutomationJSONValue = .object(["type": .string("string"), "format": .string("uuid")])

    private static func number(_ minimum: Double, _ maximum: Double, unit: String? = nil) -> AutomationJSONValue {
        var value: [String: AutomationJSONValue] = ["type": .string("number"), "minimum": .number(minimum), "maximum": .number(maximum)]
        if let unit { value["description"] = .string(unit) }
        return .object(value)
    }

    private static func integer(_ minimum: Double, _ maximum: Double) -> AutomationJSONValue {
        .object(["type": .string("integer"), "minimum": .number(minimum), "maximum": .number(maximum)])
    }

    private static func enumeration(_ values: [String]) -> AutomationJSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(AutomationJSONValue.string))])
    }

    private static func object(_ properties: [String: AutomationJSONValue], required: [String] = []) -> AutomationJSONValue {
        .object([
            "type": .string("object"), "additionalProperties": .boolean(false),
            "properties": .object(properties), "required": .array(required.map(AutomationJSONValue.string))
        ])
    }

    public static let bandSchema: AutomationJSONValue = object([
        "enabled": boolean,
        "type": enumeration(["bell", "lowShelf", "highShelf", "lowPass", "highPass", "notch"]),
        "frequencyHz": number(20, 20_000, unit: "Hz; effective frequency is bounded by the source Nyquist frequency."),
        "gainDB": number(-18, 18, unit: "dB"),
        "q": number(0.25, 16, unit: "Q for bell/pass/notch; shelf slope S uses 0.25 through 1.")
    ], required: ["enabled", "type", "frequencyHz", "gainDB", "q"])

    public static let equalizerParametersSchema: AutomationJSONValue = object([
        "bands": .object(["type": .string("array"), "minItems": .number(9), "maxItems": .number(9), "items": bandSchema])
    ], required: ["bands"])

    public static let nodeSchema: AutomationJSONValue = object([
        "nodeID": uuid, "typeID": string,
        "algorithmVersion": .object(["type": .string("integer"), "minimum": .number(1)]),
        "enabled": boolean, "channelPolicy": string,
        "quality": string,
        "parameters": .object(["type": .string("object"), "additionalProperties": .boolean(true)])
    ], required: ["nodeID", "typeID", "algorithmVersion", "enabled", "channelPolicy", "quality", "parameters"])

    public static let configurationSchema: AutomationJSONValue = object([
        "enabled": boolean,
        "inputTrimDB": number(-24, 24, unit: "dB"), "outputTrimDB": number(-24, 24, unit: "dB"),
        "headroom": object(["mode": enumeration(["automatic", "off"]), "marginDB": number(0, 12, unit: "dB")], required: ["mode", "marginDB"]),
        "nodes": .object(["type": .string("array"), "maxItems": .number(32), "items": nodeSchema])
    ], required: ["enabled", "inputTrimDB", "outputTrimDB", "headroom", "nodes"])

    public static let presetSchema: AutomationJSONValue = object([
        "schemaVersion": .object(["type": .string("integer"), "minimum": .number(1)]),
        "presetID": uuid, "name": string, "revisionString": string, "configuration": configurationSchema
    ], required: ["schemaVersion", "presetID", "name", "revisionString", "configuration"])

    private static func operation(_ name: String, fields: [String: AutomationJSONValue], required: [String]) -> AutomationJSONValue {
        object(fields.merging(["op": enumeration([name])]) { first, _ in first }, required: ["op"] + required)
    }

    private static let operationSchema: AutomationJSONValue = .object(["oneOf": .array([
        operation("setMaster", fields: ["value": boolean], required: ["value"]),
        operation("setTrim", fields: ["value": object([
            "inputTrimDB": number(-24, 24), "outputTrimDB": number(-24, 24)
        ])], required: ["value"]),
        operation("setHeadroom", fields: ["value": object([
            "mode": enumeration(["automatic", "off"]), "marginDB": number(0, 12)
        ], required: ["mode", "marginDB"])], required: ["value"]),
        operation("setParameter", fields: ["nodeID": uuid, "path": string, "value": .object([:])],
                  required: ["nodeID", "path", "value"]),
        operation("setEnabled", fields: ["nodeID": uuid, "value": boolean], required: ["nodeID", "value"]),
        operation("addNode", fields: ["node": nodeSchema], required: ["node"]),
        operation("removeNode", fields: ["nodeID": uuid], required: ["nodeID"]),
        operation("setOrder", fields: ["nodeIDs": .object([
            "type": .string("array"), "items": uuid, "uniqueItems": .boolean(true)
        ])], required: ["nodeIDs"])
    ])])

    private static let mutationFields: [String: AutomationJSONValue] = [
        "expectedRevision": string, "dryRun": boolean
    ]

    private static func mutation(_ properties: [String: AutomationJSONValue], required: [String] = []) -> AutomationJSONValue {
        object(properties.merging(mutationFields) { first, _ in first }, required: required)
    }

    private static func descriptor(_ name: String, title: String, description: String, readOnly: Bool, schema: AutomationJSONValue, dryRun: Bool = false) -> AutomationToolDescriptor {
        AutomationToolDescriptor(
            name: name, title: title, description: description, readOnly: readOnly,
            requiresConfirmation: false, scopes: [readOnly ? .audioRead : .audioWrite],
            risk: .low, supportsDryRun: dryRun, inputSchema: schema
        )
    }

    public static let descriptors: [AutomationToolDescriptor] = [
        descriptor(AutomationMethod.dspSchema, title: "DSP Schema", description: "Read the complete writable EQ/configuration schema and current node capabilities. Future effects are not advertised as runnable.", readOnly: true, schema: object([:])),
        descriptor(AutomationMethod.dspState, title: "DSP State", description: "Read complete desired configuration, presets, errors, source format and separate desired/prepared/effective/audible revisions.", readOnly: true, schema: object([:])),
        descriptor(AutomationMethod.dspValidate, title: "Validate DSP", description: "Validate a complete configuration or ordered atomic patch without changing audio or saved state.", readOnly: true, schema: object([
            "configuration": configurationSchema,
            "operations": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(128), "items": operationSchema])
        ])),
        descriptor(AutomationMethod.dspPatch, title: "Patch DSP", description: "Atomically replace the complete configuration or apply ordered edits to master enable, trims, headroom, stable node IDs, all EQ parameters and chain order. Latest valid request wins.", readOnly: false, schema: mutation([
            "configuration": configurationSchema,
            "operations": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(128), "items": operationSchema])
        ]), dryRun: true),
        descriptor(AutomationMethod.dspWait, title: "Wait for DSP", description: "Wait for one DSP application request to become audible, ready, superseded or failed. A timeout is reported separately from success.", readOnly: true, schema: object([
            "requestID": uuid, "timeoutMs": integer(0, 30_000)
        ], required: ["requestID"])),
        descriptor(AutomationMethod.dspPresetsList, title: "List DSP Presets", description: "List App-wide presets with stable UUIDs and revisions; the active working draft is separate.", readOnly: true, schema: object([
            "offset": integer(0, 100_000), "limit": integer(1, 200)
        ])),
        descriptor(AutomationMethod.dspPresetsGet, title: "Get DSP Preset", description: "Read a complete preset including disabled node parameters, channel policies, quality and chain order.", readOnly: true, schema: object(["presetID": uuid], required: ["presetID"])),
        descriptor(AutomationMethod.dspPresetsSave, title: "Save DSP Preset", description: "Save the complete working sound or explicit configuration. Omit presetID to save as a new UUID. Built-in flat cannot be overwritten; globals are excluded.", readOnly: false, schema: mutation([
            "name": string, "presetID": uuid, "expectedPresetRevision": string, "configuration": configurationSchema
        ], required: ["name"]), dryRun: true),
        descriptor(AutomationMethod.dspPresetsSelect, title: "Select DSP Preset", description: "Validate and apply the complete preset through the same live renderer transaction as the UI; selecting does not overwrite the previous preset.", readOnly: false, schema: mutation([
            "presetID": uuid, "expectedPresetRevision": string
        ], required: ["presetID"]), dryRun: true),
        descriptor(AutomationMethod.dspPresetsRename, title: "Rename DSP Preset", description: "Rename a user preset without changing its sound. UUID is the identity; names may repeat.", readOnly: false, schema: mutation([
            "presetID": uuid, "name": string, "expectedPresetRevision": string
        ], required: ["presetID", "name"]), dryRun: true),
        descriptor(AutomationMethod.dspPresetsDelete, title: "Delete DSP Preset", description: "Remove a user preset. Deleting the selected preset keeps the current sound as a working draft.", readOnly: false, schema: mutation([
            "presetID": uuid, "expectedPresetRevision": string
        ], required: ["presetID"]), dryRun: true),
        descriptor(AutomationMethod.dspPresetsDuplicate, title: "Duplicate DSP Preset", description: "Copy the complete preset into a new UUID without changing current audio.", readOnly: false, schema: mutation([
            "presetID": uuid, "name": string, "expectedPresetRevision": string
        ], required: ["presetID", "name"]), dryRun: true),
        descriptor(AutomationMethod.dspPresetsImport, title: "Import DSP Preset", description: "Preview or import a versioned JSON preset. Unknown nodes/parameters are retained; unsupported algorithms can be saved as incompatible presets without changing audio. Invalid documents are rejected; selecting incompatible algorithms fails.", readOnly: false, schema: mutation([
            "document": presetSchema
        ], required: ["document"]), dryRun: true),
        descriptor(AutomationMethod.dspPresetsExport, title: "Export DSP Preset", description: "Return the complete versioned JSON preset as a payload. No file path authorization is needed for payload exchange.", readOnly: true, schema: object(["presetID": uuid], required: ["presetID"])),
        descriptor(AutomationMethod.dspErrorsGet, title: "DSP Errors", description: "Read bounded DSP diagnostics with node/field/revision details.", readOnly: true, schema: object([:])),
        descriptor(AutomationMethod.dspErrorsClear, title: "Clear DSP Errors", description: "Clear historical error presentation; this does not retry or enable a faulted node.", readOnly: false, schema: object([:]))
    ]
}
