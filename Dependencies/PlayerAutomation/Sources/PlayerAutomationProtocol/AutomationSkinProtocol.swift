import Foundation

/// Release gate shared by the App and its automation tools. Set it to false to ship a build
/// without custom skin entry points.
public enum SkinCustomizationAvailability {
    public static let isEnabled = false
}

public extension AutomationMethod {
    static let skinCapabilities = "skin.capabilities"
    static let skinCheck = "skin.check"
    static let skinReload = "skin.reload"
    static let skinRuntime = "skin.runtime"
}

public enum AutomationSkinToolCatalog {
    public static let descriptors: [AutomationToolDescriptor] = SkinCustomizationAvailability.isEnabled ? [
        .init(name: AutomationMethod.skinCapabilities, title: "Skin Capabilities", description: "Read implemented native scene v2 node, data, function, action and component names.", readOnly: true, scopes: [.settingsRead], risk: .low, inputSchema: schema([:])),
        .init(name: AutomationMethod.skinCheck, title: "Check Skin", description: "Parse and compile a local v2 author directory without installing or selecting it. Does not launch a preview or compile Metal shaders.", readOnly: true, scopes: [.settingsRead, .filesRead], risk: .low, inputSchema: schema(["directory": string], required: ["directory"])),
        .init(name: AutomationMethod.skinReload, title: "Reload Skin", description: "Validate and reload an installed or linked skin. Failure keeps the previous program and runtime generation.", readOnly: false, scopes: [.settingsWrite], risk: .low, inputSchema: schema(["skinID": string], required: ["skinID"])),
        .init(name: AutomationMethod.skinRuntime, title: "Skin Runtime", description: "Read active native scene evaluation counters and audio leases. Counters are runtime observations, not a CPU or memory profiler.", readOnly: true, scopes: [.settingsRead], risk: .low, inputSchema: schema([:]))
    ] : []
    private static let string: AutomationJSONValue = .object(["type": .string("string")])
    private static func schema(_ properties: [String: AutomationJSONValue], required: [String] = []) -> AutomationJSONValue {
        .object(["type": .string("object"), "additionalProperties": .boolean(false), "properties": .object(properties), "required": .array(required.map(AutomationJSONValue.string))])
    }
}
