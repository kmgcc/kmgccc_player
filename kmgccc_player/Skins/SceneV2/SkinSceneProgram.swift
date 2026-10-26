import Foundation
import SwiftUI

/// The on-disk v2 language. Author data stays intact for export and development reload.
struct SkinSceneV2Document: Codable, Equatable {
    var root: SkinParameterValue
    var state: [String: SkinParameterValue] = [:]
    var components: [String: SkinParameterValue] = [:]
    var events: [String: SkinParameterValue] = [:]

    private enum CodingKeys: String, CodingKey { case root, state, components, events }

    init(root: SkinParameterValue, state: [String: SkinParameterValue] = [:],
         components: [String: SkinParameterValue] = [:], events: [String: SkinParameterValue] = [:]) {
        self.root = root; self.state = state; self.components = components; self.events = events
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        root = try keys.decode(SkinParameterValue.self, forKey: .root)
        state = try keys.decodeIfPresent([String: SkinParameterValue].self, forKey: .state) ?? [:]
        components = try keys.decodeIfPresent([String: SkinParameterValue].self, forKey: .components) ?? [:]
        events = try keys.decodeIfPresent([String: SkinParameterValue].self, forKey: .events) ?? [:]
    }
}

struct SkinSceneError: LocalizedError {
    var file = "skin.json"
    let path: String
    let message: String
    var errorDescription: String? { "\(file) \(path)：\(message)" }
}

indirect enum SkinCompiledProperty {
    case expression(SkinCompiledExpression)
    case array([SkinCompiledProperty])
    case object([String: SkinCompiledProperty])

    var domains: Set<SkinDataDomain> {
        switch self {
        case .expression(let value): value.domains
        case .array(let values): values.reduce(into: []) { $0.formUnion($1.domains) }
        case .object(let values): values.values.reduce(into: []) { $0.formUnion($1.domains) }
        }
    }
    /// Domains read by the parts of this value that change every frame.
    var frameDomains: Set<SkinDataDomain> {
        switch self {
        case .expression(let value): value.tier == .frame ? value.domains : []
        case .array(let values): values.reduce(into: []) { $0.formUnion($1.frameDomains) }
        case .object(let values): values.values.reduce(into: []) { $0.formUnion($1.frameDomains) }
        }
    }
    var sources: [String] {
        switch self {
        case .expression(let value): [value.source]
        case .array(let values): values.flatMap(\.sources)
        case .object(let values): values.values.flatMap(\.sources)
        }
    }
    var tier: SkinDataTier {
        switch self {
        case .expression(let value): value.tier
        case .array(let values): values.map(\.tier).max() ?? .constant
        case .object(let values): values.values.map(\.tier).max() ?? .constant
        }
    }
    func evaluate(_ context: SkinEvaluationContext) -> SkinValue {
        switch self {
        case .expression(let value): value.evaluate(context)
        case .array(let values): .list(values.map { $0.evaluate(context) })
        case .object(let values): .record(values.mapValues { $0.evaluate(context) })
        }
    }
}

struct SkinCompiledAction {
    let name: String
    var value: SkinCompiledProperty?
    var key: String?
    var condition: SkinCompiledExpression?
}

struct SkinCompiledVariant {
    let condition: SkinCompiledExpression
    let properties: [String: SkinCompiledProperty]
}

struct SkinCompiledWatch {
    let value: SkinCompiledProperty
    let actions: [SkinCompiledAction]
    /// Also runs once when the node appears.
    var initial = false
}

final class SkinCompiledSceneNode: Identifiable {
    let id: String
    let type: String
    let properties: [String: SkinCompiledProperty]
    let children: [SkinCompiledSceneNode]
    let variants: [SkinCompiledVariant]
    let actions: [String: [SkinCompiledAction]]
    let mask: SkinCompiledSceneNode?
    let component: String?
    let watches: [SkinCompiledWatch]
    /// Computed once; the renderer reads these on every evaluation.
    let tier: SkinDataTier
    let ownDomains: Set<SkinDataDomain>
    let domains: Set<SkinDataDomain>
    /// Hover state is tracked only for nodes that read `self` or handle hover events.
    let tracksPointer: Bool
    /// True when every per-frame input stands still while playback is paused, so the
    /// node's display timeline can pause with it. Free-running time and pointer idle keep it live.
    let pausesWithPlayback: Bool

    private static func ownTier(properties: [String: SkinCompiledProperty], variants: [SkinCompiledVariant]) -> SkinDataTier {
        (properties.values.map(\.tier) + variants.map { max($0.condition.tier, $0.properties.values.map(\.tier).max() ?? .constant) }).max() ?? .constant
    }

    private static func collectDomains(type: String, component: String?, properties: [String: SkinCompiledProperty], variants: [SkinCompiledVariant],
                                       actions: [String: [SkinCompiledAction]], watches: [SkinCompiledWatch]) -> Set<SkinDataDomain> {
        var result = properties.values.reduce(into: Set<SkinDataDomain>()) { $0.formUnion($1.domains) }
        if component == "behavior.lyricsEndAutoHide" { result.formUnion([.lyrics, .lyricsTimeline, .clock]) }
        for variant in variants {
            result.formUnion(variant.condition.domains)
            for value in variant.properties.values { result.formUnion(value.domains) }
        }
        for commands in actions.values {
            for command in commands {
                result.formUnion(command.value?.domains ?? [])
                result.formUnion(command.condition?.domains ?? [])
            }
        }
        for watch in watches { result.formUnion(watch.value.domains) }
        if ["spectrum", "waveform", "meter", "particles", "shader"].contains(type) { result.insert(.audio) }
        if ["particles", "shader", "fog"].contains(type) { result.insert(.time) }
        if type == "lyricLine" { result.formUnion([.clock, .lyricsTimeline]) }
        // Uncoloured text and shapes follow the theme's foreground.
        if ["text", "lyricLine", "symbol", "shape"].contains(type), properties["color"] == nil { result.insert(.theme) }
        return result
    }

    init(id: String, type: String, properties: [String: SkinCompiledProperty],
         children: [SkinCompiledSceneNode], variants: [SkinCompiledVariant],
         actions: [String: [SkinCompiledAction]], mask: SkinCompiledSceneNode?, component: String?, watches: [SkinCompiledWatch] = []) {
        self.id = id; self.type = type; self.properties = properties; self.children = children
        self.variants = variants; self.actions = actions; self.mask = mask; self.component = component
        self.watches = watches
        // A camera moves its children's geometry on its own timeline, so it never puts the layer there.
        let evaluated = properties.filter { $0.key != "glyphMotion" && $0.key != "camera" }
        tier = Self.ownTier(properties: properties.filter { $0.key != "camera" }, variants: variants)
        let own = Self.collectDomains(type: type, component: component, properties: properties, variants: variants, actions: actions, watches: watches)
        ownDomains = own
        var all = own
        for child in children { all.formUnion(child.domains) }
        if let mask { all.formUnion(mask.domains) }
        domains = all
        let sources = properties.values.flatMap(\.sources) + variants.flatMap { [$0.condition.source] + $0.properties.values.flatMap(\.sources) }
        tracksPointer = actions["hoverStart"] != nil || actions["hoverEnd"] != nil || sources.contains { $0.contains("self.") }
        var frame = properties.filter { $0.key != "camera" }.values.reduce(into: Set<SkinDataDomain>()) { $0.formUnion($1.frameDomains) }
        for variant in variants {
            if variant.condition.tier == .frame { frame.formUnion(variant.condition.domains) }
            for value in variant.properties.values { frame.formUnion(value.frameDomains) }
        }
        for watch in watches { frame.formUnion(watch.value.frameDomains) }
        if ["particles", "shader", "fog"].contains(type) { frame.insert(.time) }
        // A plain text's glyphs keep their own clock from the moment the text appears.
        pausesWithPlayback = properties["keyframes"] == nil && frame.isDisjoint(with: [.time, .host])
            && !(type == "text" && properties["glyphMotion"] != nil)
        nodeValues = evaluated
        camera = properties["camera"]
        cameraPausesWithPlayback = camera.map { $0.frameDomains.isDisjoint(with: [.time, .host]) } ?? true
        let frameKeys = Set(evaluated.filter { $0.value.tier == .frame }.keys)
        frameValues = evaluated.filter { frameKeys.contains($0.key) }
        steadyValues = evaluated.filter { !frameKeys.contains($0.key) }
        var steadyDomains = steadyValues.values.reduce(into: Set<SkinDataDomain>()) { $0.formUnion($1.domains) }
        for variant in variants { steadyDomains.formUnion(variant.condition.domains); variant.properties.values.forEach { steadyDomains.formUnion($0.domains) } }
        // Clock, lyric timing and audio are read live rather than through observed writes.
        cachesSteadyValues = !frameKeys.isEmpty && steadyDomains.isDisjoint(with: [.clock, .lyricsTimeline, .audio, .time])
            && variants.allSatisfy { variant in
                variant.condition.tier != .frame && variant.properties.allSatisfy { $0.value.tier != .frame && !frameKeys.contains($0.key) }
            }
    }

    /// Everything but `glyphMotion`, which the text renderer evaluates once per glyph, and
    /// `camera`, which its layer's children evaluate on their own timeline.
    private let nodeValues: [String: SkinCompiledProperty]
    private let frameValues: [String: SkinCompiledProperty]
    private let steadyValues: [String: SkinCompiledProperty]
    /// True when a per-frame node can keep its other values until the scene data changes.
    let cachesSteadyValues: Bool
    let camera: SkinCompiledProperty?
    let cameraPausesWithPlayback: Bool

    func values(_ context: SkinEvaluationContext) -> [String: SkinValue] {
        var result = nodeValues.mapValues { $0.evaluate(context) }
        for variant in variants where variant.condition.evaluate(context).isTruthy {
            result.merge(variant.properties.mapValues { $0.evaluate(context) }) { _, new in new }
        }
        return result
    }

    /// Per-frame values over steady values kept in `cache` while the data revision, locals and
    /// live viewport stay the same.
    func values(_ context: SkinEvaluationContext, cache: SkinNodeValueCache) -> [String: SkinValue] {
        guard cachesSteadyValues else { return values(context) }
        var result = cache.steady(revision: context.data.revision, locals: context.locals, size: context.live?.size) {
            var steady = steadyValues.mapValues { $0.evaluate(context) }
            for variant in variants where variant.condition.evaluate(context).isTruthy {
                steady.merge(variant.properties.mapValues { $0.evaluate(context) }) { _, new in new }
            }
            return steady
        }
        for (key, value) in frameValues { result[key] = value.evaluate(context) }
        return result
    }

    var repeatLimit: Int {
        if type != "repeat" { return 1 }
        if case .expression(let value) = properties["limit"], let limit = value.constantValue?.numberValue { return Int(min(1024, max(1, limit))) }
        if case .array(let values) = properties["items"] { return min(1024, values.count) }
        if case .expression(let value) = properties["items"], let items = value.constantValue { return min(1024, items.listValue.count) }
        if case .expression(let value) = properties["count"], let count = value.constantValue?.numberValue { return Int(min(1024, max(0, count))) }
        return 1024
    }

    /// Cells a column `repeat` directly inside `scroll` keeps built at once; the rest are made as they scroll in.
    static let lazyCellBudget = 48

    func maximumInstances(of type: String? = nil, insideScroll: Bool = false) -> Int {
        let own = type == nil || self.type == type ? 1 : 0
        let instances = children.map { $0.maximumInstances(of: type, insideScroll: self.type == "scroll") }
        let total = self.type == "switch" ? (instances.max() ?? 0) : min(2001, instances.reduce(0, +))
        let cells = insideScroll && buildsLazily ? min(repeatLimit, Self.lazyCellBudget) : repeatLimit
        return min(2001, own + total * cells + (mask?.maximumInstances(of: type) ?? 0))
    }

    private var buildsLazily: Bool {
        guard type == "repeat" else { return false }
        guard let layout = properties["layout"] else { return true }
        if case .expression(let value) = layout, let constant = value.constantValue { return constant.textValue != "row" }
        return false
    }

    /// Every component this subtree mounts, so settings can offer the host options it relies on.
    var componentNames: Set<String> {
        var result = children.reduce(into: Set<String>()) { $0.formUnion($1.componentNames) }
        if let mask { result.formUnion(mask.componentNames) }
        if let component { result.insert(component) }
        return result
    }

    /// Whether any node asks for `adaptive` ink, so the scene only maps the backdrop when needed.
    var readsBackdrop: Bool {
        var own = false
        if case .expression(let value)? = properties["adaptive"] { own = value.constantValue?.isTruthy != false }
        return own || children.contains(where: \.readsBackdrop) || mask?.readsBackdrop == true
    }

    /// The App lyrics settings groups the native lyrics leave to the user; nil leaves all of them.
    var lyricsUserSettings: Set<String>? {
        if component == "lyrics.native", case .object(let props) = properties["props"], let value = props["userSettings"] {
            switch value {
            case .expression(let expression):
                guard let constant = expression.constantValue else { return nil }
                if case .list(let items) = constant { return Set(items.map(\.textValue)) }
                return NativeLyricsConfigurationMapper.allowedUserSettings(constant.textValue)
            case .array(let items):
                return Set(items.compactMap { item -> String? in
                    if case .expression(let expression) = item { return expression.constantValue?.textValue }
                    return nil
                })
            case .object: return nil
            }
        }
        return children.lazy.compactMap(\.lyricsUserSettings).first ?? mask?.lyricsUserSettings
    }

    var referencedAssets: Set<String> {
        var result = children.reduce(into: Set<String>()) { $0.formUnion($1.referencedAssets) }
        if let mask { result.formUnion(mask.referencedAssets) }
        if ["image", "video", "shader"].contains(type), case .expression(let path) = properties["path"], let value = path.constantValue { result.insert(value.textValue) }
        // Custom filters name their compiled shader library.
        var filters: [SkinCompiledProperty] = []
        switch properties["filter"] {
        case .array(let items)?: filters = items
        case let item?: filters = [item]
        case nil: break
        }
        for case .object(let fields) in filters {
            if case .expression(let library)? = fields["library"], let value = library.constantValue { result.insert(value.textValue) }
        }
        return result
    }
}

/// One node instance's steady values. A reference type, so filling it during a frame does not
/// invalidate the view.
final class SkinNodeValueCache {
    private var revision: UInt64?
    private var locals: [String: SkinValue] = [:]
    private var size: CGSize?
    private var values: [String: SkinValue] = [:]

    func steady(revision: UInt64, locals: [String: SkinValue], size: CGSize?, make: () -> [String: SkinValue]) -> [String: SkinValue] {
        if revision != self.revision || size != self.size || locals != self.locals {
            values = make(); self.revision = revision; self.locals = locals; self.size = size
        }
        return values
    }
}

struct SkinSceneProgram {
    let root: SkinCompiledSceneNode
    let state: [String: SkinValue]
    let events: [String: [SkinCompiledAction]]
    let nodeCount: Int
    var domains: Set<SkinDataDomain> {
        var result = root.domains.union([.playback, .viewport, .host])
        if events["trackChange"] != nil { result.insert(.track) }
        if events["artworkChange"] != nil || events["motionArtworkReady"] != nil { result.insert(.artwork) }
        if events["themeChange"] != nil { result.insert(.theme) }
        if events["lyricsChange"] != nil || events["lyricLineChange"] != nil || events["interludeStart"] != nil || events["interludeEnd"] != nil { result.formUnion([.lyrics, .lyricsTimeline]) }
        for commands in events.values { for command in commands { result.formUnion(command.value?.domains ?? []); result.formUnion(command.condition?.domains ?? []) } }
        return result
    }
    var scene: SkinScene {
        SkinScene { snapshot, viewport, components in
            SkinSceneV2View(program: self, snapshot: snapshot, viewport: viewport, components: components)
        }
    }
}

extension SkinParameterValue {
    var objectValue: [String: SkinParameterValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [SkinParameterValue]? { if case .array(let value) = self { value } else { nil } }
    var stringValue: String? { if case .text(let value) = self { value } else { nil } }
}
