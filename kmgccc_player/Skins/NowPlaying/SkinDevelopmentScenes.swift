#if DEBUG
import SwiftUI

/// Opt-in native v2 compositions. Promotion of built-ins requires visual acceptance.
/// Each keeps the bundled skin's presentation, parameters and settings, so the host treats it
/// like the original and only the scene decides the composition.
enum SkinDevelopmentScenes {
    @MainActor static func packages(in catalog: SkinCatalog) -> [PackagedSkin] {
        SkinBuiltinSceneTemplates.names.compactMap { name in
            guard let document = SkinBuiltinSceneTemplates.document(name),
                  let program = SkinBuiltinSceneTemplates.program(name),
                  let renderer = catalog.nativePreset(for: SkinBuiltinSceneTemplates.presetID(name)) else { return nil }
            let descriptor = renderer.descriptor.withIdentity(id: "development.v2." + name, name: renderer.name + " v2")
            return PackagedSkin(
                manifest: .init(descriptor: descriptor, nativePreset: renderer.id,
                                parameters: renderer.parameterDefinitions, sceneV2: document),
                origin: .bundled, renderer: renderer, programs: ["default": program]
            )
        }
    }
}
#endif
