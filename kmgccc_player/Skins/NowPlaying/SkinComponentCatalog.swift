import SwiftUI
import Observation

/// Components are registered by identity, so a new renderer does not add a host switch.
@MainActor
@Observable
final class SkinComponentCatalog {
    typealias Factory = (SkinSceneSnapshot, SkinComponentConfiguration) -> AnyView
    private var factories: [String: Factory] = [:]
    private var interactiveTypes: Set<String> = []
    func contains(_ id: String) -> Bool { factories[id] != nil }

    func register<Content: View>(
        _ id: String,
        isInteractive: Bool = false,
        @ViewBuilder content: @escaping (SkinSceneSnapshot, SkinComponentConfiguration) -> Content
    ) {
        if isInteractive { interactiveTypes.insert(id) }
        else { interactiveTypes.remove(id) }
        factories[id] = { snapshot, configuration in
            AnyView(content(snapshot, configuration))
        }
    }

    func makeComponent(
        _ id: String,
        snapshot: SkinSceneSnapshot,
        configuration: SkinComponentConfiguration
    ) -> AnyView {
        guard let content = factories[id]?(snapshot, configuration) else { return AnyView(EmptyView()) }
        return interactiveTypes.contains(id) ? AnyView(content.skinControlRegion()) : content
    }
}

/// Component-local values. A component interprets its own keys; the scene host does not.
struct SkinComponentConfiguration: Codable, Equatable {
    var bindings: [String: String] = [:]
    var values: [String: SkinParameterValue] = [:]

    func resolving(parameters: [String: SkinParameterValue]) -> Self {
        var resolved = self
        for (key, parameterID) in bindings {
            if let value = parameters[parameterID] { resolved.values[key] = value }
        }
        return resolved
    }

    subscript(_ key: String) -> SkinParameterValue? { values[key] }
}

/// JSON-compatible values keep author parameters separate from renderer implementation types.
enum SkinParameterValue: Codable, Equatable {
    case boolean(Bool)
    case number(Double)
    case text(String)
    case array([SkinParameterValue])
    case object([String: SkinParameterValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .text(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Self].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct SkinComponents {
    let catalog: SkinComponentCatalog
    let snapshot: SkinSceneSnapshot
    var parameters: [String: SkinParameterValue] = [:]

    func component(
        _ id: String,
        configuration: SkinComponentConfiguration = .init()
    ) -> AnyView {
        catalog.makeComponent(id, snapshot: snapshot, configuration: configuration.resolving(parameters: parameters))
    }
}
