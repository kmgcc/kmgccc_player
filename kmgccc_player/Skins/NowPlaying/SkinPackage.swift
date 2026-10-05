import SwiftUI

struct SkinPackageManifest: Codable {
    var formatVersion = 1
    var hostAPIVersion = 1
    var version = "1.0.0"
    var descriptor: SkinDescriptor
    /// The optional native preset supplies the existing artwork/background and settings adapters.
    var nativePreset: String?
    var scene: SkinSceneDocument?
    var parameters: [SkinParameterDefinition] = []
}

enum SkinPackageOrigin {
    case bundled
    case installed(URL)
}

/// Built-in and imported definitions use the same adapter; origin only controls management.
struct PackagedSkin: NowPlayingSkin {
    let manifest: SkinPackageManifest
    let origin: SkinPackageOrigin
    let renderer: (any NowPlayingSkin)?

    var isExportable: Bool {
        if case .installed = origin { return true }
        return false
    }

    var descriptor: SkinDescriptor { manifest.descriptor }
    var scene: SkinScene? { manifest.scene?.scene ?? renderer?.scene }
    var parameterDefinitions: [SkinParameterDefinition] { manifest.parameters }

    func makeBackground(context: SkinContext) -> AnyView {
        renderer?.makeBackground(context: context) ?? AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        renderer?.makeArtwork(context: context) ?? AnyView(SkinArtworkComponent(snapshot: .init(context: context)))
    }

    func makeOverlay(context: SkinContext) -> AnyView? { renderer?.makeOverlay(context: context) }
    var settingsView: AnyView? { renderer?.settingsView }
    var fullscreenSettingsView: AnyView? { renderer?.fullscreenSettingsView }
    func releaseCachedResources() async { await renderer?.releaseCachedResources() }
}
