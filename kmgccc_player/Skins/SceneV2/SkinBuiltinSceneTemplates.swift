import SwiftUI

/// Native compositions are author templates too. Each template draws the backdrop the host would
/// draw (`background.host`, so the art background follows the user's setting), the bundled skin's
/// artwork and overlay in host layout, and places lyrics and the mini player from `host.layout`.
/// An author can copy a template and move any of these pieces.
enum SkinBuiltinSceneTemplates {
    static let names = ["classicLED", "appleStyle", "rotatingCover", "cassette", "coverGradientBlur"]
    static var ids: Set<String> { Set(names.map { "template." + $0 }) }

    static func presetID(_ name: String) -> String? {
        switch name {
        case "classicLED": ClassicLEDSkin.id
        case "appleStyle": AppleStyleSkin.skinID
        case "rotatingCover": RotatingCoverSkin.id
        case "cassette": "kmgccc.cassette"
        case "coverGradientBlur": "fullscreen.coverGradientBlur"
        default: nil
        }
    }

    static func document(_ name: String) -> SkinSceneV2Document? {
        guard let preset = presetID(name) else { return nil }
        func frame(_ x: String, _ y: String, _ width: String, _ height: String) -> SkinParameterValue {
            .object(["x": .text(x), "y": .text(y), "width": .text(width), "height": .text(height)])
        }
        func hostFrame(_ key: String) -> SkinParameterValue {
            .object(["x": .text("=host.layout.\(key).x"), "y": .text("=host.layout.\(key).y"),
                     "width": .text("=host.layout.\(key).width"), "height": .text("=host.layout.\(key).height"),
                     "anchor": .text("topLeading")])
        }
        func component(_ id: String, frame value: SkinParameterValue, props: [String: SkinParameterValue] = [:],
                       extra: [String: SkinParameterValue] = [:]) -> SkinParameterValue {
            .object(["type": .text("component"), "component": .text(id), "frame": value, "props": .object(props)]
                .merging(extra) { _, new in new })
        }
        let full = frame("50%", "50%", "100%", "100%")
        let hostLayout: [String: SkinParameterValue] = ["layout": .text("host")]
        // Cover blur draws its artwork as the backdrop, as the host does.
        let artworkIsBackdrop = name == "coverGradientBlur"
        var children: [SkinParameterValue] = [component("background.host", frame: full, props: ["preset": .text(preset)])]
        if !artworkIsBackdrop {
            children.append(component("builtin.\(preset).artwork", frame: full, props: hostLayout))
            children.append(component("builtin.\(preset).overlay", frame: full, props: hostLayout))
        }
        children.append(component("lyrics.native", frame: hostFrame("lyrics"), extra: ["visible": .text("=host.lyricsVisible")]))
        // Over cover blur the host reads the backdrop beneath the controls; `adaptive` does the same.
        children.append(component("behavior.autoHide", frame: hostFrame("miniPlayer"),
            props: ["delay": .text("=prefs.miniPlayerAutoHide")],
            extra: ["children": .array([component("control.miniPlayer", frame: frame("50%", "50%", "100%", "100%"))]),
                    "adaptive": .boolean(artworkIsBackdrop)]))
        return .init(root: .object(["type": .text("layer"), "children": .array(children)]))
    }

    /// Templates are fixed documents; compile each once per process.
    @MainActor private static var programs: [String: SkinSceneProgram] = [:]

    @MainActor static func program(_ name: String) -> SkinSceneProgram? {
        if let program = programs[name] { return program }
        guard let document = document(name) else { return nil }
        do {
            let program = try SkinSceneCompiler.compile(document, file: "template.\(name)")
            programs[name] = program
            return program
        } catch {
            Log.warning("Skin template failed: \(error.localizedDescription)", category: .ui)
            return nil
        }
    }
}

struct SkinBuiltinTemplatePart: View {
    let name: String
    let snapshot: SkinSceneSnapshot
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.skinSceneFullscreenHost) private var host
    @Environment(SkinManager.self) private var manager
    var body: some View {
        GeometryReader { proxy in
            if let program = SkinBuiltinSceneTemplates.program(name) {
                SkinSceneV2View(program: program, snapshot: snapshot,
                    viewport: .init(size: proxy.size, surface: surface, fullscreenHost: host),
                    components: .init(catalog: manager.catalog.components, snapshot: snapshot))
            }
        }
    }
}
