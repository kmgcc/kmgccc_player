import Foundation

enum SkinSceneCompiler {
    static let nodeTypes: Set<String> = ["layer", "row", "column", "stack", "grid", "scroll", "repeat", "switch", "use", "component", "glassGroup", "lyrics", "spacer", "text", "lyricLine", "image", "artwork", "video", "shape", "gradient", "symbol", "spectrum", "waveform", "meter", "shader", "particles", "fog"]
    static let actionNames: Set<String> = ["playPause", "play", "pause", "stop", "next", "previous", "seek", "seekBy", "seekAndResume", "seekToLyric", "setVolume", "setOrderMode", "setAppleMusicMode", "toggleLike", "toggleDislike", "setLike", "playlist.add", "playlist.new", "track.delete", "musicInfo.open", "artist.show", "album.show", "output.select", "queue.toggle", "queue.show", "queue.hide", "queue.play", "lyrics.toggle", "lyrics.show", "lyrics.hide","fullscreen.toggle", "fullscreen.enter", "fullscreen.exit", "quickPanel.open", "settings.open", "trackDetail.open", "trackEdit.open", "externalInfo.open", "skin.reload", "skin.restore", "state.set", "state.toggle", "state.reset", "params.set"]
    static let filterNames: Set<String> = ["chromatic", "glitch", "motionBlur", "scanlines", "wave", "grain", "custom"]
    static let effectNames: Set<String> = ["blur", "brightness", "contrast", "saturation", "grayscale", "hueRotation", "invert", "blendMode"]
    static let propertyNames: Set<String> = ["frame", "visible", "opacity", "rotation", "scale", "scaleX", "scaleY", "offsetX", "offsetY", "zIndex", "blur", "brightness", "contrast", "saturation", "grayscale", "hueRotation", "invert", "blendMode", "cornerRadius", "clip", "background", "material", "glass", "appGlass", "border", "shadow", "animation", "keyframes", "hitTesting", "controls", "cursor", "help", "text", "fontSize", "font", "weight", "color", "lineLimit", "alignment", "spacing", "columns", "items", "layout", "when", "props", "name", "path", "fit", "shape", "points", "colors", "start", "end", "count", "gain", "lineWidth", "function", "speed", "size", "lifetime", "seed", "loop", "muted", "poster", "mode", "index", "watch", "contextMenu", "effects", "limit", "scrollTo", "adaptive", "highlightColor", "highlightStyle", "measure", "transition", "stops", "radius", "tracking", "lineSpacing", "design", "italic", "minScale", "key", "track", "motion", "enter", "group", "glyphMotion", "outline", "filter", "bloom", "camera", "depth", "stroke", "trimStart", "trimEnd", "warp", "extrude", "angle", "spread", "trail"]
    static let sceneEvents: Set<String> = ["trackChange", "artworkChange", "motionArtworkReady", "playbackStart", "playbackPause", "seek", "volumeChange", "orderChange", "lyricsChange", "lyricLineChange", "interludeStart", "interludeEnd", "themeChange", "viewportChange", "visibilityChange", "fullscreenHostChange", "lyricsVisibilityChange", "audioAvailabilityChange"]
    static let nodeEvents: Set<String> = ["tap", "doubleTap", "longPress", "hoverStart", "hoverEnd", "appear", "disappear", "scroll", "dragStart", "drag", "dragEnd"]
    private static let structuralKeys: Set<String> = ["type", "id", "children", "template", "cases", "default", "component", "variants", "on", "mask"]

    static func compile(_ document: SkinSceneV2Document, parameters: [SkinParameterDefinition] = [], requires: [String] = [], file: String = "skin.json") throws -> SkinSceneProgram {
        if let missing = requires.first(where: { !SkinHostCapabilities.all.contains($0) }) {
            throw SkinSceneError(file: file, path: "$.requires", message: "宿主未提供能力 \(missing)")
        }
        var environment = SkinCompileEnvironment()
        environment.hostCapabilities = SkinHostCapabilities.all
        environment.params = Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, SkinValue($0.defaultValue).type) })
        environment.state = document.state.mapValues { SkinValue($0).type }
        var compiler = Compiler(document: document, environment: environment, file: file)
        let root = try compiler.node(document.root, path: "$.scene.root", environment: environment, depth: 0, templates: [])
        guard compiler.lyricsCount(root) <= 1 else { throw SkinSceneError(file: file, path: "$.scene.root", message: "每个场景支持一个原生歌词组件") }
        guard compiler.capsuleBalances(root) == [0] else { throw SkinSceneError(file: file, path: "$.scene.root", message: "官方左右胶囊须在每个布局中成对出现") }
        guard root.maximumInstances() <= 2000, root.maximumInstances(of: "shader") <= 4,
              root.maximumInstances(of: "particles") <= 4, root.maximumInstances(of: "fog") <= 4, root.maximumInstances(of: "video") <= 2 else {
            throw SkinSceneError(file: file, path: "$.scene.root", message: "展开后的场景超过节点或效果数量限制")
        }
        for name in document.events.keys where !sceneEvents.contains(name) {
            throw SkinSceneError(file: file, path: "$.scene.events." + name, message: "未知场景事件" + skinSuggestion(name, in: sceneEvents))
        }
        let events = try document.events.mapValues { try compiler.actions($0, path: "$.scene.events", environment: environment) }
        return SkinSceneProgram(root: root, state: document.state.mapValues(SkinValue.init), events: events, nodeCount: compiler.count)
    }

    private struct Compiler {
        let document: SkinSceneV2Document
        let environment: SkinCompileEnvironment
        let file: String
        var count = 0
        var ids: Set<String> = []
        var resources: [String: Int] = [:]

        func error(_ path: String, _ message: String) -> SkinSceneError { .init(file: file, path: path, message: message) }

        mutating func node(_ raw: SkinParameterValue, path: String, environment: SkinCompileEnvironment, depth: Int, templates: Set<String>) throws -> SkinCompiledSceneNode {
            guard depth < 64 else { throw error(path, "节点嵌套超过 64 层") }
            count += 1
            guard count <= 2000 else { throw error(path, "场景节点超过 2000 个") }
            guard var fields = raw.objectValue, let type = fields["type"]?.stringValue else { throw error(path, "节点需要 type") }
            guard SkinSceneCompiler.nodeTypes.contains(type) else {
                throw error(path + ".type", "未知节点 \(type)" + skinSuggestion(type, in: SkinSceneCompiler.nodeTypes))
            }
            let knownKeys = SkinSceneCompiler.propertyNames.union(SkinSceneCompiler.structuralKeys)
            for key in fields.keys where !knownKeys.contains(key) {
                throw error(path + "." + key, "未知节点属性 \(key)" + skinSuggestion(key, in: knownKeys))
            }
            if type == "component", let component = fields["component"]?.stringValue, component.hasPrefix("template."),
               var template = SkinBuiltinSceneTemplates.document(String(component.dropFirst(9)))?.root.objectValue {
                for (key, value) in fields where !["type", "component", "props"].contains(key) { template[key] = value }
                return try node(.object(template), path: path + "." + component, environment: environment, depth: depth + 1, templates: templates)
            }
            if let effects = fields["effects"] {
                guard let array = effects.arrayValue else { throw error(path + ".effects", "需要效果数组") }
                for effect in array {
                    guard let values = effect.objectValue, let type = values["type"]?.stringValue,
                          SkinSceneCompiler.effectNames.contains(type), values["value"] != nil else { throw error(path + ".effects", "未知效果或缺少 value") }
                }
            }
            if type == "use" {
                guard let name = fields["name"]?.stringValue, !templates.contains(name),
                      var template = (document.components[name] ?? (name.hasPrefix("template.") ? SkinBuiltinSceneTemplates.document(String(name.dropFirst(9)))?.root : nil))?.objectValue else { throw error(path, "组件模板缺失或循环引用") }
                var templateEnvironment = environment
                for (key, value) in fields["props"]?.objectValue ?? [:] {
                    templateEnvironment.props[key] = try expression(value, path: path + ".props." + key, environment: environment)
                }
                for (key, value) in fields where !["type", "name", "props"].contains(key) { template[key] = value }
                return try node(.object(template), path: path + ".use(\(name))", environment: templateEnvironment, depth: depth + 1, templates: templates.union([name]))
            }
            if ["shader", "particles", "video", "fog"].contains(type) {
                resources[type, default: 0] += 1
                guard resources[type, default: 0] <= (type == "video" ? 2 : 4) else { throw error(path, "\(type) 节点超过数量限制") }
            }
            let id = path + ":" + (fields["id"]?.stringValue ?? type)
            guard ids.insert(id).inserted else { throw error(path + ".id", "节点 ID 重复：\(id)") }
            var component = fields["component"]?.stringValue
            if type == "lyrics" { component = "lyrics.native" }
            if type == "component", component == nil { throw error(path, "component 节点需要组件名称") }
            if let component, !SkinComponentContract.isKnown(component) {
                throw error(path + ".component", "未知组件 \(component)" + skinSuggestion(component, in: SkinComponentContract.ids.union(SkinComponentContract.presetParts)))
            }
            if component == "lyrics.native" {
                for key in (fields["props"]?.objectValue ?? [:]).keys where !SkinComponentContract.lyricsProps.contains(key) {
                    throw error(path + ".props." + key, "原生歌词不支持 \(key)" + skinSuggestion(key, in: SkinComponentContract.lyricsProps))
                }
            }
            if type == "shader", let function = fields["function"] {
                // The name is spliced into the host's fragment entry point, so it must be a plain identifier.
                guard let name = function.stringValue, name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else {
                    throw error(path + ".function", "着色器函数名须为常量标识符")
                }
            }
            if fields["camera"] != nil, type != "layer" { throw error(path + ".camera", "camera 只用于 layer") }
            if let filter = fields["filter"] {
                for entry in filter.arrayValue ?? [filter] {
                    guard let name = entry.objectValue?["type"]?.stringValue, SkinSceneCompiler.filterNames.contains(name) else {
                        throw error(path + ".filter", "滤镜需要 type" + skinSuggestion(entry.objectValue?["type"]?.stringValue ?? "", in: SkinSceneCompiler.filterNames))
                    }
                    if name == "custom" {
                        guard let library = entry.objectValue?["library"]?.stringValue, library.hasSuffix(".metallib"), !library.hasPrefix("=") else {
                            throw error(path + ".filter.library", "custom 滤镜需要包内常量 .metallib 路径")
                        }
                        guard let function = entry.objectValue?["function"]?.stringValue,
                              function.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else {
                            throw error(path + ".filter.function", "着色器函数名须为常量标识符")
                        }
                    }
                }
            }
            if type == "repeat", let limit = fields["limit"] {
                guard case .number(let value) = limit, value >= 1, value <= 1024 else { throw error(path + ".limit", "limit 须为 1 至 1024 的常量") }
            }
            var childEnvironment = environment
            if type == "repeat" { childEnvironment.locals.formUnion(["item", "index", "count"]) }
            var childValues = fields["children"]?.arrayValue ?? []
            if type == "repeat" {
                guard let template = fields["template"] else { throw error(path, "repeat 需要 template") }
                childValues = [template]
            }
            if type == "switch" {
                childValues = fields["cases"]?.arrayValue ?? []
                if let fallback = fields["default"] { childValues.append(fallback) }
            }
            var children: [SkinCompiledSceneNode] = []
            let siblingIDs = childValues.compactMap { $0.objectValue?["id"]?.stringValue }
            guard Set(siblingIDs).count == siblingIDs.count else { throw error(path + ".children", "子节点 ID 重复") }
            for (index, child) in childValues.enumerated() {
                children.append(try node(child, path: path + ".children[\(index)]", environment: childEnvironment, depth: depth + 1, templates: templates))
            }
            if type == "repeat", children.contains(where: { lyricsCount($0) > 0 }) { throw error(path, "原生歌词不能放在 repeat 中") }
            let mask = try fields["mask"].map { try node($0, path: path + ".mask", environment: environment, depth: depth + 1, templates: templates) }
            var properties: [String: SkinCompiledProperty] = [:]
            for (key, value) in fields where SkinSceneCompiler.propertyNames.contains(key) {
                // Actions carry a separate grammar; they must not turn into value expressions.
                if ["watch", "contextMenu"].contains(key) { continue }
                if key == "glyphMotion" {
                    guard ["text", "lyricLine"].contains(type) else { throw error(path + "." + key, "glyphMotion 只用于 text 与 lyricLine") }
                    var glyphEnvironment = environment; glyphEnvironment.locals.insert("glyph")
                    properties[key] = try property(value, path: path + "." + key, environment: glyphEnvironment, key: key)
                    continue
                }
                properties[key] = try property(value, path: path + "." + key, environment: environment, key: key)
            }
            if ["image", "video", "shader"].contains(type) {
                guard case .expression(let value) = properties["path"], let resource = value.constantValue?.textValue, !resource.isEmpty else {
                    throw error(path + ".path", "素材路径须为包内常量路径")
                }
            }
            var variants: [SkinCompiledVariant] = []
            for (index, rawVariant) in (fields["variants"]?.arrayValue ?? []).enumerated() {
                guard var variant = rawVariant.objectValue, let condition = variant.removeValue(forKey: "when") else { throw error(path + ".variants[\(index)]", "需要 when") }
                var values: [String: SkinCompiledProperty] = [:]
                for (key, value) in variant {
                    guard SkinSceneCompiler.propertyNames.contains(key) else { throw error(path + ".variants", "未知属性 \(key)") }
                    values[key] = try property(value, path: path + ".variants[\(index)]." + key, environment: environment, key: key)
                }
                variants.append(.init(condition: try expression(condition, path: path + ".variants[\(index)].when", expected: .boolean, environment: environment), properties: values))
            }
            var handlers: [String: [SkinCompiledAction]] = [:]
            var eventEnvironment = environment; eventEnvironment.locals.insert("gesture")
            for (key, value) in fields["on"]?.objectValue ?? [:] {
                guard SkinSceneCompiler.nodeEvents.contains(key) else {
                    throw error(path + ".on." + key, "未知事件" + skinSuggestion(key, in: SkinSceneCompiler.nodeEvents))
                }
                handlers[key] = try actions(value, path: path + ".on." + key, environment: eventEnvironment)
            }
            var watches: [SkinCompiledWatch] = []
            for (index, rawWatch) in (fields["watch"]?.arrayValue ?? []).enumerated() {
                guard let watch = rawWatch.objectValue, let value = watch["value"], let commands = watch["do"] else { throw error(path + ".watch[\(index)]", "需要 value 和 do") }
                var initial = false
                if let flag = watch["initial"] {
                    guard case .boolean(let value) = flag else { throw error(path + ".watch[\(index)].initial", "initial 须为布尔常量") }
                    initial = value
                }
                watches.append(.init(value: try property(value, path: path + ".watch[\(index)].value", environment: environment),
                                     actions: try actions(commands, path: path + ".watch[\(index)].do", environment: environment), initial: initial))
            }
            if let menu = fields["contextMenu"]?.arrayValue {
                for (index, item) in menu.enumerated() {
                    guard let object = item.objectValue, let title = object["title"], let command = object["do"] else { throw error(path + ".contextMenu", "菜单项需要 title 和 do") }
                    properties["menuTitle\(index)"] = try property(title, path: path + ".contextMenu", environment: environment)
                    handlers["menu\(index)"] = try actions(command, path: path + ".contextMenu", environment: environment)
                }
            }
            fields.removeAll()
            return .init(id: id, type: type, properties: properties, children: children, variants: variants, actions: handlers, mask: mask, component: component, watches: watches)
        }

        func expression(_ raw: SkinParameterValue, path: String, expected: SkinValueType = .any, environment: SkinCompileEnvironment) throws -> SkinCompiledExpression {
            do { return try SkinExpressionCompiler.compile(raw, expected: expected, environment: environment) }
            catch { throw self.error(path, error.localizedDescription) }
        }

        func property(_ raw: SkinParameterValue, path: String, environment: SkinCompileEnvironment, key: String = "") throws -> SkinCompiledProperty {
            switch raw {
            case .object(let values): return .object(try values.mapValues { try property($0, path: path, environment: environment) })
            case .array(let values): return .array(try values.enumerated().map { try property($0.element, path: path + "[\($0.offset)]", environment: environment) })
            default:
                let numbers: Set<String> = ["opacity", "rotation", "scale", "scaleX", "scaleY", "offsetX", "offsetY", "zIndex", "blur", "brightness", "contrast", "saturation", "grayscale", "hueRotation", "cornerRadius", "fontSize", "spacing", "columns", "count", "gain", "lineWidth", "speed", "lifetime", "seed", "limit", "scrollTo", "radius", "tracking", "lineSpacing", "minScale", "depth", "trimStart", "trimEnd", "warp", "angle", "spread", "trail"]
                let booleans: Set<String> = ["visible", "hitTesting", "when", "clip", "invert", "adaptive", "measure", "italic"]
                let expected: SkinValueType = numbers.contains(key) ? .number : booleans.contains(key) ? .boolean : ["color", "background", "tint", "highlightColor"].contains(key) ? .color : .any
                return .expression(try expression(raw, path: path, expected: expected, environment: environment))
            }
        }

        func actions(_ raw: SkinParameterValue, path: String, environment: SkinCompileEnvironment) throws -> [SkinCompiledAction] {
            if case .array(let values) = raw { return try values.flatMap { try actions($0, path: path, environment: environment) } }
            let fields = raw.objectValue ?? [:]
            guard let name = raw.stringValue ?? fields["do"]?.stringValue, SkinSceneCompiler.actionNames.contains(name) else {
                let name = raw.stringValue ?? fields["do"]?.stringValue ?? ""
                throw error(path, "未知操作 \(name)" + skinSuggestion(name, in: SkinSceneCompiler.actionNames))
            }
            let key = fields["state"]?.stringValue ?? fields["key"]?.stringValue
            if name.hasPrefix("state."), name != "state.reset", key.map({ environment.state[$0] != nil }) != true { throw error(path, "操作需要已声明的 state 名称") }
            return [.init(name: name, value: try fields["value"].map { try property($0, path: path + ".value", environment: environment) }, key: key,
                          condition: try fields["when"].map { try expression($0, path: path + ".when", expected: .boolean, environment: environment) })]
        }

        func lyricsCount(_ node: SkinCompiledSceneNode) -> Int {
            let own = ["lyrics.native", "lyrics.panel"].contains(node.component ?? "") ? 1 : 0
            let childCount = node.type == "switch" ? (node.children.map(lyricsCount).max() ?? 0) : node.children.map(lyricsCount).reduce(0, +)
            return own + childCount + (node.mask.map(lyricsCount) ?? 0)
        }

        func capsuleBalances(_ node: SkinCompiledSceneNode) -> Set<Int> {
            if case .expression(let value) = node.properties["visible"], value.constantValue?.isTruthy == false { return [0] }
            if node.component == "control.leadingCapsule" { return [1] }
            if node.component == "control.volumeCapsule" { return [-1] }
            if node.type == "switch" { return node.children.reduce(into: Set<Int>()) { $0.formUnion(capsuleBalances($1)) } }
            return node.children.reduce(into: Set([0])) { totals, child in
                totals = Set(totals.flatMap { value in capsuleBalances(child).map { value + $0 } })
            }
        }
    }
}
