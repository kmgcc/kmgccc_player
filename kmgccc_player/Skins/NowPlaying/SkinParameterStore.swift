import Foundation
import Observation

@Observable
@MainActor
final class SkinParameterStore {
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var revision: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func values(
        skinID: String,
        surface: SkinSurface,
        definitions: [SkinParameterDefinition]
    ) -> [String: SkinParameterValue] {
        _ = revision
        let savedValues = storedValues(skinID: skinID, surface: surface)
        return definitions.reduce(into: [:]) { result, definition in
            guard definition.surfaces.contains(surface) else { return }
            result[definition.id] = definition.resolvedValue(savedValues[definition.id])
        }
    }

    func value(
        skinID: String,
        surface: SkinSurface,
        definition: SkinParameterDefinition
    ) -> SkinParameterValue {
        _ = revision
        guard definition.surfaces.contains(surface) else { return definition.defaultValue }
        return definition.resolvedValue(storedValues(skinID: skinID, surface: surface)[definition.id])
    }

    func set(
        skinID: String,
        surface: SkinSurface,
        definition: SkinParameterDefinition,
        value: SkinParameterValue
    ) {
        var savedValues = storedValues(skinID: skinID, surface: surface)
        savedValues[definition.id] = definition.resolvedValue(value)
        if let data = try? JSONEncoder().encode(savedValues) {
            defaults.set(data, forKey: storageKey(skinID: skinID, surface: surface))
        }
        revision &+= 1
    }

    private func storedValues(skinID: String, surface: SkinSurface) -> [String: SkinParameterValue] {
        guard let data = defaults.data(forKey: storageKey(skinID: skinID, surface: surface)) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: SkinParameterValue].self, from: data)) ?? [:]
    }

    private func storageKey(skinID: String, surface: SkinSurface) -> String {
        "skin.authorParameters.\(skinID).\(surface.rawValue)"
    }
}
