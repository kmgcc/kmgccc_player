import SwiftUI

struct SkinPackageManifest: Codable {
    var formatVersion = 2
    var hostAPIVersion = 2
    var version = "1.0.0"
    var descriptor: SkinDescriptor
    /// The optional native preset supplies the existing artwork/background and settings adapters.
    var nativePreset: String?
    var scene: SkinSceneDocument?
    var parameters: [SkinParameterDefinition] = []
    var sceneV2: SkinSceneV2Document?
    var scenePath: String?
    var scenes: [String: SkinSceneV2Document] = [:]
    var requires: [String] = []
    var uses: [String] = []
    var fonts: [String] = []
}

enum SkinPackageOrigin {
    case bundled
    case installed(URL)
    case development(URL)
}

/// Built-in and imported definitions use the same adapter; origin only controls management.
struct PackagedSkin: NowPlayingSkin {
    let manifest: SkinPackageManifest
    let origin: SkinPackageOrigin
    let renderer: (any NowPlayingSkin)?
    var programs: [String: SkinSceneProgram] = [:]

    var isExportable: Bool {
        switch origin { case .installed, .development: true; case .bundled: false }
    }

    var descriptor: SkinDescriptor { manifest.descriptor }
    /// Components the compiled scenes mount; settings show the host options these rely on.
    var sceneComponents: Set<String> {
        programs.values.reduce(into: Set<String>()) { $0.formUnion($1.root.componentNames) }
    }
    var lyricsUserSettings: Set<String>? {
        programs.values.lazy.compactMap(\.root.lyricsUserSettings).first
    }
    /// Whether this surface's compiled scene mounts the native lyric surface; nil without one.
    func sceneMountsNativeLyrics(on surface: SkinSurface) -> Bool? {
        guard let program = programs[surface.rawValue] ?? programs["default"] else { return nil }
        return !program.root.componentNames.isDisjoint(with: ["lyrics.native", "lyrics.panel"])
    }
    var scene: SkinScene? {
        guard !programs.isEmpty else { return manifest.scene?.scene ?? renderer?.scene }
        return SkinScene { snapshot, viewport, components in
            if let program = programs[viewport.surface.rawValue] ?? programs["default"] {
                SkinSceneV2View(program: program, snapshot: snapshot, viewport: viewport, components: components)
            }
        }
    }
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
