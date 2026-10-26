import AppKit
import MotionKit
import SwiftUI

struct SkinSceneV2View: View {
    let program: SkinSceneProgram
    let snapshot: SkinSceneSnapshot
    let viewport: SkinViewport
    let components: SkinComponents
    @State private var data = SkinSceneData()
    @State private var fonts = SkinFontLease()
    @State private var resourceError: String?
    @State private var metricsID = UUID().uuidString
    @State private var didPrepare = false
    @State private var backdrop = SkinBackdropReadability()
    @State private var readsBackdrop = false
    @Environment(\.skinPackageResources) private var resources
    @Environment(\.skinPackageFonts) private var fontPaths
    @Environment(\.skinSceneLyricsVisible) private var lyricsVisible
    @Environment(\.skinScenePresentation) private var presentation

    var body: some View {
        Group {
            if didPrepare { SkinSceneNodeV2View(node: program.root, data: data, components: components, size: viewport.size) }
            else { Color.clear }
        }
            // Layout follows the window as it is dragged: units read this frame's size, and
            // implicit animations sit out the resize so nodes do not spring after the edge.
            .environment(\.skinSceneLiveViewport, SkinLiveViewport(size: viewport.size, surface: viewport.surface,
                                                                   lyricsVisible: lyricsVisible, presentation: presentation))
            .transaction(value: viewport.size) { $0.disablesAnimations = true }
            .coordinateSpace(.named(SkinBackdropReadability.space))
            .environment(\.skinBackdropReadability, backdrop)
            .task(id: readsBackdrop ? "\(snapshot.track?.id.uuidString ?? "")|\(snapshot.track?.artworkChecksum ?? 0)" : nil) {
                guard readsBackdrop else { return }
                await backdrop.load(key: "\(snapshot.track?.id.uuidString ?? "")|\(snapshot.track?.artworkChecksum ?? 0)", artwork: snapshot.track?.artworkData)
            }
            .onChange(of: viewport.size, initial: true) { _, size in backdrop.setViewport(size) }
            .background {
                SkinSceneFeeds(data: data, program: program, snapshot: snapshot, viewport: viewport, parameters: components.parameters)
            }
            .onAppear {
                guard !didPrepare else { return }
                didPrepare = true
                readsBackdrop = program.root.readsBackdrop
                SkinSceneRuntimeMetrics.shared.mount(metricsID, nodes: program.nodeCount)
                data.initialState = program.state; data.resetState(program.state)
                do { try fonts.load(paths: fontPaths, root: resources) }
                catch { resourceError = error.localizedDescription }
            }
            .onDisappear { fonts.release(); didPrepare = false; SkinSceneRuntimeMetrics.shared.unmount(metricsID) }
            .environment(\.skinSceneMetricsID, metricsID)
            .environment(\.skinSceneData, data)
            .alert("皮肤资源", isPresented: Binding(get: { resourceError != nil }, set: { if !$0 { resourceError = nil } })) {
                Button("好", role: .cancel) { resourceError = nil }
            } message: { Text(resourceError ?? "") }
            .modifier(SkinSceneEventModifier(program: program, data: data))
    }
}

struct SkinSceneNodeV2View: View {
    let node: SkinCompiledSceneNode
    let data: SkinSceneData
    let components: SkinComponents
    let size: CGSize
    var locals: [String: SkinValue] = [:]
    var positioned = false
    /// A `repeat` directly inside `scroll` builds only the cells in view.
    var lazy = false
    /// The enclosing layer's camera, for a positioned child.
    var camera: SkinCameraLink?
    @Environment(\.skinSceneIsActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.skinPackageResources) private var resources
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneMetricsID) private var metricsID
    @Environment(\.skinSceneLiveViewport) private var live
    @State private var hovered = false
    @State private var dragging = false
    @State private var animationStart = Date.timeIntervalSinceReferenceDate
    @State private var backdropReading: SkinBackdropReading?
    @State private var measuredFrame: CGRect?
    @State private var glyphClock = SkinGlyphClock()
    @State private var valueCache = SkinNodeValueCache()
    @State private var cameraSource = SkinCameraSource()
    @Environment(\.skinBackdropReading) private var inheritedReading
    @Namespace private var glassNamespace

    private var needsFrames: Bool {
        node.tier == .frame || node.watches.contains(where: { $0.value.tier == .frame }) || node.properties["keyframes"] != nil || node.properties["glyphMotion"] != nil
            || ["spectrum", "waveform", "meter", "particles", "shader", "fog", "lyricLine"].contains(node.type)
    }

    /// Clock, lyric and audio inputs stand still while paused; free-running time keeps going.
    private var framesPaused: Bool {
        !active || (node.pausesWithPlayback && !components.snapshot.playback.isPlaying)
    }

    var body: some View {
        Group {
            if needsFrames {
                TimelineView(.animation(minimumInterval: nil, paused: framesPaused)) { timeline in
                    render(at: timeline.date.timeIntervalSinceReferenceDate)
                        .onChange(of: timeline.date) { _, _ in SkinSceneRuntimeMetrics.shared.frame(metricsID, audioReaders: data.audioReaders.count) }
                }
            } else { render(at: Date.timeIntervalSinceReferenceDate) }
        }
    }

    private func context(now: Double, gesture: SkinValue? = nil) -> SkinEvaluationContext {
        var values = locals
        var own: [String: SkinValue] = ["hovered": .boolean(hovered), "pressed": .boolean(dragging), "dragging": .boolean(dragging)]
        if case .record(let reading)? = (backdropReading ?? inheritedReading)?.value { own.merge(reading) { _, new in new } }
        if let frame = measuredFrame {
            own.merge(["x": .number(frame.minX), "y": .number(frame.minY), "width": .number(frame.width), "height": .number(frame.height),
                       "midX": .number(frame.midX), "midY": .number(frame.midY)]) { _, new in new }
        }
        values["self"] = .record(own)
        values["parent"] = .record(["width": .number(size.width), "height": .number(size.height)])
        if let gesture { values["gesture"] = gesture }
        return SkinEvaluationContext(data: data, locals: values, now: now, live: live)
    }

    private func render(at now: Double) -> AnyView {
        let context = context(now: now)
        var values = node.values(context, cache: valueCache)
        for effect in values["effects"]?.listValue ?? [] {
            let name = effect[member: "type"].textValue
            if SkinSceneCompiler.effectNames.contains(name) { values[name] = effect[member: "value"] }
        }
        applyKeyframes(&values, now: now)
        // With a transition the node stays mounted and animates to its hidden look instead.
        let hidden = values["visible"]?.isTruthy == false
        let transition = values["transition"]
        guard !hidden || transition != nil else { return AnyView(EmptyView()) }
        let frame = values["frame"] ?? .null
        let width = dimension(frame[member: "width"], horizontal: true) ?? dimension(frame[member: "size"], horizontal: true)
        let height = dimension(frame[member: "height"], horizontal: false) ?? dimension(frame[member: "size"], horizontal: false)
        let childSize = CGSize(width: width ?? size.width, height: height ?? size.height)
        var result = content(values, size: childSize, now: now)
        result = AnyView(result.frame(width: width, height: height, alignment: alignment(frame[member: "align"].textValue)))
        result = AnyView(result.frame(minWidth: dimension(frame[member: "minWidth"], horizontal: true), maxWidth: dimension(frame[member: "maxWidth"], horizontal: true), minHeight: dimension(frame[member: "minHeight"], horizontal: false), maxHeight: dimension(frame[member: "maxHeight"], horizontal: false)))
        if let aspect = frame[member: "aspectRatio"].numberValue, aspect > 0 { result = AnyView(result.aspectRatio(aspect, contentMode: .fit)) }
        if frame[member: "fill"].isTruthy {
            result = AnyView(result.frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        result = AnyView(result.padding(frame[member: "padding"].number()))
        // `group` composites the subtree first, so blend modes inside it mix only with each other.
        if values["group"]?.isTruthy == true { result = AnyView(result.compositingGroup()) }
        // A hidden node that keeps its transition stays mounted; its effects stop with it.
        let dormant = hidden || (values["opacity"]?.number(1) ?? 1) <= 0
        if let filter = values["filter"] {
            result = AnyView(result.modifier(SkinSceneFilters(filters: filter.type == .list ? filter.listValue : [filter], dormant: dormant)))
        }
        if let bloom = values["bloom"] { result = AnyView(result.modifier(SkinSceneBloom(value: bloom, dormant: dormant))) }
        result = SkinNodeStyle.apply(result, values: values, reduceTransparency: reduceTransparency)
        if let key = values["key"] {
            result = AnyView(SkinKeyedSwap(key: String(describing: key), transition: transition ?? .null, content: result))
        }
        if values["adaptive"]?.isTruthy == true {
            result = AnyView(result.modifier(SkinAdaptiveBackdropProbe(reading: $backdropReading)))
        }
        if values["measure"]?.isTruthy == true {
            result = AnyView(result.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SkinBackdropReadability.space)) } action: { rect in
                if measuredFrame != rect { measuredFrame = rect }
            })
        }
        if let transition, values["key"] == nil || values["visible"] != nil {
            result = AnyView(result.modifier(SkinVisibilityTransition(value: transition, hidden: hidden)))
        }
        if let mask = node.mask {
            result = AnyView(result.mask(SkinSceneNodeV2View(node: mask, data: data, components: components, size: childSize, locals: locals)))
        }
        if let enter = values["enter"] {
            result = AnyView(result.modifier(SkinEnterTransition(value: enter)))
        }
        let tokens = SkinMotion.tokens(motionTokens, override: values["motion"])
        if let animation = values["animation"] {
            let spec = SkinMotion.spec(animation, tokens: tokens)
            // Per-frame values are already continuous; animating them would chase every frame.
            let animated = values.filter { node.properties[$0.key]?.tier != .frame }
            result = AnyView(result.motionAnimation(spec, value: animated))
        }
        if node.tracksPointer {
            result = AnyView(result.onHover { inside in
                hovered = inside; data.pointerMoved()
                perform(inside ? "hoverStart" : "hoverEnd", now: now)
            })
        }
        result = AnyView(result
            .onAppear {
                animationStart = Date.timeIntervalSinceReferenceDate
                if node.ownDomains.contains(.audio) { data.audioReaders.insert(readerID) }
                perform("appear", now: now)
            }
            .onDisappear { data.audioReaders.remove(readerID); perform("disappear", now: now) }
            .onChange(of: values["keyframes"]?[member: "trigger"]) { _, _ in animationStart = Date.timeIntervalSinceReferenceDate })
        if let help = values["help"]?.textValue { result = AnyView(result.help(help)) }
        if let cursor = values["cursor"]?.textValue { result = AnyView(result.background(SkinSceneCursorRegion(name: cursor))) }
        if let controls = values["controls"] { result = AnyView(result.skinProvidesControls(Set(controls.listValue.compactMap { SkinSceneControl(rawValue: $0.textValue) }))) }
        if node.actions["scroll"] != nil {
            result = AnyView(result.background(SkinSceneScrollRegion { x, y in
                perform("scroll", now: Date.timeIntervalSinceReferenceDate, gesture: .record(["deltaX": .number(x), "deltaY": .number(y)]))
            }))
        }
        for watch in node.watches {
            result = AnyView(result.onChange(of: watch.value.evaluate(context), initial: watch.initial) { _, _ in
                SkinSceneActionRunner.run(watch.actions, context: self.context(now: Date.timeIntervalSinceReferenceDate), actions: actions)
            })
        }
        let menuKeys = node.actions.keys.filter { $0.hasPrefix("menu") }.sorted()
        if !menuKeys.isEmpty {
            // A snapshot menu from AppKit, so the open menu survives per-frame redraws.
            result = AnyView(result.overlay {
                SkinMenuAnchor(opensOnClick: false) {
                    NSHostingMenu(rootView: ForEach(menuKeys, id: \.self) { key in
                        Button(values["menuTitle" + key.dropFirst(4)]?.textValue ?? "") { perform(key, now: Date.timeIntervalSinceReferenceDate) }
                    })
                }
            })
        }
        // The double tap must be attached first, or the single tap claims every click.
        if node.actions["doubleTap"] != nil { result = AnyView(result.contentShape(Rectangle()).onTapGesture(count: 2) { perform("doubleTap", now: now) }.skinControlRegion()) }
        if node.actions["tap"] != nil { result = AnyView(result.contentShape(Rectangle()).onTapGesture { perform("tap", now: now) }.skinControlRegion()) }
        if node.actions["longPress"] != nil { result = AnyView(result.onLongPressGesture { perform("longPress", now: now) }) }
        if ["drag", "dragStart", "dragEnd"].contains(where: { node.actions[$0] != nil }) {
            result = AnyView(result.gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let gesture = gestureValue(value, size: childSize)
                if !dragging { dragging = true; perform("dragStart", now: Date.timeIntervalSinceReferenceDate, gesture: gesture) }
                perform("drag", now: Date.timeIntervalSinceReferenceDate, gesture: gesture)
            }.onEnded { value in
                dragging = false; perform("dragEnd", now: Date.timeIntervalSinceReferenceDate, gesture: gestureValue(value, size: childSize))
            }).skinControlRegion())
        }
        // Applied after the gestures: a hidden node that keeps its transition stays mounted, and a
        // full-viewport tap layer would otherwise catch every click. The modifiers stay in place
        // either way, so toggling visibility keeps the subtree's identity.
        let interactive = values["hitTesting"]?.isTruthy != false && !hidden
        let reportsControls = interactive && (values["opacity"]?.number(1) ?? 1) > 0
        result = AnyView(result
            .allowsHitTesting(interactive)
            .transformPreference(SkinControlRegionKey.self) { if !interactive { $0 = [] } }
            .transformPreference(SkinSceneControlsKey.self) { if !reportsControls { $0 = [] } })
        if values["motion"] != nil { result = AnyView(result.environment(\.motionTokens, tokens)) }
        // Positioning comes last: `.position` fills the parent layer, so any hit shape,
        // hover or help attached after it would claim the whole layer.
        if positioned {
            let anchor = frame[member: "anchor"].textValue
            let point = unitPoint(anchor.isEmpty ? "center" : anchor)
            let x = dimension(frame[member: "x"], horizontal: true, signed: true) ?? size.width / 2
            let y = dimension(frame[member: "y"], horizontal: false, signed: true) ?? size.height / 2
            let centre = CGPoint(x: x + (0.5 - point.x) * (width ?? 0), y: y + (0.5 - point.y) * (height ?? 0))
            // A free repeat hands the camera on to its cells instead of following it as a whole.
            if let camera, !(node.type == "repeat" && values["layout"]?.textValue == "free") {
                let paused = !active || (camera.source.pausesWithPlayback && !components.snapshot.playback.isPlaying)
                result = AnyView(result.modifier(SkinCameraFollow(link: camera, centre: centre, depth: values["depth"]?.number() ?? 0, size: size, paused: paused)))
            }
            result = AnyView(result.position(centre))
        }
        if let zIndex = values["zIndex"]?.numberValue { result = AnyView(result.zIndex(zIndex)) }
        return result
    }

    private var readerID: String { node.id + ":" + (locals["index"]?.textValue ?? "") }

    private func child(_ node: SkinCompiledSceneNode, size: CGSize, positioned: Bool = false, locals: [String: SkinValue]? = nil, camera: SkinCameraLink? = nil) -> some View {
        SkinSceneNodeV2View(node: node, data: data, components: components, size: size, locals: locals ?? self.locals, positioned: positioned, camera: camera)
    }

    private func content(_ values: [String: SkinValue], size: CGSize, now: Double) -> AnyView {
        let spacing = values["spacing"]?.number(12) ?? 12
        let foreground = values["color"]?.colorValue?.swiftUIColor ?? (backdropReading ?? inheritedReading)?.primary
            ?? data.theme["theme.appForeground.primary"]?.colorValue?.swiftUIColor ?? .primary
        switch node.type {
        case "layer":
            let link = cameraLink(now: now)
            let stack = AnyView(ZStack(alignment: .topLeading) { ForEach(node.children) { child($0, size: size, positioned: true, camera: link) } }.frame(width: size.width, height: size.height))
            guard let link else { return stack }
            let paused = !active || (link.source.pausesWithPlayback && !components.snapshot.playback.isPlaying)
            return AnyView(stack.modifier(SkinCameraTurn(link: link, paused: paused)))
        case "row": return AnyView(HStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } })
        case "column": return AnyView(VStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } })
        case "stack":
            if values["layout"]?.textValue == "row" { return AnyView(HStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } }) }
            return AnyView(VStack(spacing: spacing) { ForEach(node.children) { child($0, size: size) } })
        case "grid":
            let columns = max(1, min(64, values["columns"]?.integer(2) ?? 2))
            return AnyView(LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) { ForEach(node.children) { child($0, size: CGSize(width: size.width / Double(columns), height: size.height)) } })
        case "scroll":
            let target = values["scrollTo"]?.numberValue.map { Int($0) }
            return AnyView(SkinSceneFollowingScroll(target: target) {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(node.children) { SkinSceneNodeV2View(node: $0, data: data, components: components, size: size, locals: locals, lazy: true) }
                }
            }.frame(width: size.width, height: size.height))
        case "repeat":
            let items = Array((values["items"]?.listValue ?? []).prefix(node.repeatLimit))
            // `free`: cells are positioned like a layer's children by their own frame x/y, and
            // follow the enclosing layer's camera with their own depth.
            let free = values["layout"]?.textValue == "free"
            let cells = AnyView(ForEach(items.indices, id: \.self) { index in
                if let template = node.children.first {
                    let scoped = locals.merging(["item": items[index], "index": .number(Double(index)), "count": .number(Double(items.count))]) { _, new in new }
                    // Repeat cells carry their index so a scroll can follow `scrollTo`.
                    child(template, size: size, positioned: free, locals: scoped, camera: free ? camera : nil).id(index)
                }
            })
            if free { return AnyView(ZStack(alignment: .topLeading) { cells }.frame(width: size.width, height: size.height)) }
            if values["layout"]?.textValue == "row" { return AnyView(HStack(spacing: spacing) { cells }) }
            return lazy ? AnyView(LazyVStack(alignment: .leading, spacing: spacing) { cells }) : AnyView(VStack(alignment: .leading, spacing: spacing) { cells })
        case "switch":
            if let selected = node.children.first(where: { $0.values(context(now: now))["when"]?.isTruthy != false }) { return AnyView(child(selected, size: size)) }
            return AnyView(EmptyView())
        case "glassGroup": return AnyView(GlassEffectContainer(spacing: spacing) { ZStack { ForEach(node.children) { child($0, size: size) } }.environment(\.skinSceneGlassNamespace, glassNamespace) })
        case "component", "lyrics":
            return components.component(node.component ?? "lyrics.native", configuration: .init(values: (values["props"] ?? .record([:])).parameterValue.objectValue ?? [:]), children: AnyView(ZStack { ForEach(node.children) { child($0, size: size) } }))
        case "spacer": return AnyView(Spacer(minLength: values["size"]?.number() ?? 0))
        case "text", "lyricLine":
            let lyricTime = data.clock.lyricsTime(at: now)
            let offset = values["index"]?.integer() ?? 0
            let mode = values["mode"]?.textValue ?? ""
            let field = ["translation", "romanization"].contains(mode) ? mode : "text"
            let value = node.type == "lyricLine" ? data.lyricsTimeline.line(relative: offset, time: lyricTime)[member: field].textValue : values["text"]?.textValue ?? ""
            let fontSize = values["fontSize"]?.number(24) ?? 24
            let font = values["font"]?.textValue ?? ""
            var typeface = font.isEmpty
                ? Font.system(size: fontSize, weight: skinFontWeight(values["weight"]?.textValue ?? "regular"), design: skinFontDesign(values["design"]?.textValue ?? ""))
                : Font.custom(font, size: fontSize)
            if values["italic"]?.isTruthy == true { typeface = typeface.italic() }
            let tracking = values["tracking"]?.number() ?? 0
            func layout(_ text: Text) -> some View {
                text.font(typeface).tracking(tracking)
                    .multilineTextAlignment(textAlignment(values["alignment"]?.textValue ?? ""))
                    .lineSpacing(values["lineSpacing"]?.number() ?? 0)
                    .lineLimit(values["lineLimit"].map { max(1, $0.integer(1)) })
                    .minimumScaleFactor((values["minScale"]?.number(1) ?? 1).clamped01)
            }
            let lineIndex = data.lyricsTimeline.currentIndex(at: lyricTime) + offset
            let glyphs = glyphStyle(values, text: value, lineIndex: node.type == "lyricLine" ? lineIndex : nil, lyricTime: lyricTime, now: now, fontSize: fontSize)
            if node.type == "lyricLine", let highlight = values["highlightColor"]?.colorValue {
                // Word by word: each word moves toward `highlightColor` as it is sung, so wrapped lines stay right.
                if values["highlightStyle"]?.textValue == "word", field == "text",
                   let words = data.lyricsTimeline.wordProgress(index: lineIndex, time: lyricTime) {
                    let base = values["color"]?.colorValue ?? (backdropReading ?? inheritedReading).map { OKLCHColor($0.profile.primary) }
                        ?? data.theme["theme.appForeground.primary"]?.colorValue ?? .white
                    let line = words.reduce(Text("")) { text, word in
                        Text("\(text)\(Text(word.text).foregroundStyle(base.mixed(with: highlight, amount: word.progress).swiftUIColor))")
                    }
                    return AnyView(SkinGlyphLayer(style: glyphs, content: layout(line)))
                }
                // A sweep: the sung part takes `highlightColor`, left to right.
                let fraction = data.lyricsTimeline.sungFraction(index: lineIndex, time: lyricTime)
                return AnyView(SkinGlyphLayer(style: glyphs, content: layout(Text(value)).foregroundStyle(foreground).overlay {
                    layout(Text(value)).foregroundStyle(highlight.swiftUIColor).mask(alignment: .leading) {
                        GeometryReader { proxy in Rectangle().frame(width: proxy.size.width * fraction) }
                    }
                }))
            }
            return AnyView(SkinGlyphLayer(style: glyphs, content: layout(Text(value)).foregroundStyle(foreground)))
        case "symbol": return AnyView(Image(systemName: values["name"]?.textValue ?? "circle").resizable().scaledToFit().foregroundStyle(foreground))
        case "artwork":
            if let id = values["track"]?.textValue, let trackID = UUID(uuidString: id) {
                return AnyView(SkinQueueTrackArtwork(trackID: trackID, fills: values["fit"]?.textValue == "fill"))
            }
            return components.component("artwork.basic", configuration: .init(values: values.mapValues(\.parameterValue)))
        case "image": return AnyView(SkinPackageImage(path: values["path"]?.textValue ?? "", fit: values["fit"]?.textValue ?? "fit"))
        case "video": return AnyView(SkinPackageVideo(path: values["path"]?.textValue ?? "", active: active, isPlaying: components.snapshot.playback.isPlaying))
        case "shape":
            let shape = SkinSceneShape(kind: values["shape"]?.textValue ?? "rectangle", points: values["points"]?.textValue ?? "")
            let trimmed = shape.trim(from: (values["trimStart"]?.number() ?? 0).clamped01, to: (values["trimEnd"]?.number(1) ?? 1).clamped01)
            // `stroke` draws the outline; the shape is filled as well only when it names a `color`.
            guard let stroke = values["stroke"] else { return AnyView(trimmed.fill(foreground)) }
            let style = StrokeStyle(lineWidth: max(0, stroke.numberValue ?? stroke[member: "width"].number(1)),
                                    lineCap: stroke[member: "cap"].textValue == "round" ? .round : stroke[member: "cap"].textValue == "square" ? .square : .butt,
                                    lineJoin: stroke[member: "join"].textValue == "round" ? .round : stroke[member: "join"].textValue == "bevel" ? .bevel : .miter,
                                    dash: stroke[member: "dash"].listValue.map { CGFloat(max(0, $0.number())) })
            let line = trimmed.stroke(stroke[member: "color"].colorValue?.swiftUIColor ?? foreground, style: style)
            return values["color"] == nil ? AnyView(line) : AnyView(shape.fill(foreground).overlay(line))
        case "fog":
            let colors = (values["colors"]?.listValue ?? []).compactMap { $0.colorValue?.swiftUIColor }
            let moves = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full
            return AnyView(SkinSceneFog(low: colors.count > 1 ? colors[0] : .clear, high: colors.last ?? foreground,
                                        time: moves ? data.time(at: now).truncatingRemainder(dividingBy: 3600) : 0,
                                        feature: values["size"]?.number(260) ?? 260, speed: values["speed"]?.number(0.3) ?? 0.3,
                                        warp: values["warp"]?.number(1.5) ?? 1.5, gain: values["gain"]?.number(1.2) ?? 1.2))
        case "gradient":
            let gradient = skinGradient(values)
            switch values["mode"]?.textValue ?? "" {
            case "radial":
                let radius = max(1, (values["radius"]?.number(0.5) ?? 0.5) * max(size.width, size.height))
                return AnyView(RadialGradient(gradient: gradient, center: unitPoint(values["start"]?.textValue ?? "center"), startRadius: 0, endRadius: radius))
            case "elliptical":
                // Stretches to the frame, so a glow in a wide frame ends inside it instead of at its edges.
                return AnyView(EllipticalGradient(gradient: gradient, center: unitPoint(values["start"]?.textValue ?? "center"),
                                                  startRadiusFraction: 0, endRadiusFraction: values["radius"]?.number(0.5) ?? 0.5))
            case "angular":
                return AnyView(AngularGradient(gradient: gradient, center: unitPoint(values["start"]?.textValue ?? "center")))
            default:
                return AnyView(LinearGradient(gradient: gradient, startPoint: unitPoint(values["start"]?.textValue ?? "topLeading"), endPoint: unitPoint(values["end"]?.textValue ?? "bottomTrailing")))
            }
        case "spectrum", "waveform", "meter": return AnyView(SkinSceneAudioCanvas(kind: node.type, data: data, values: values, now: now, color: components.snapshot.theme.accentColor))
        case "particles": return AnyView(SkinSceneParticles(data: data, values: values, now: now, reduceMotion: reduceMotion))
        case "shader": return AnyView(SkinSceneShader(path: values["path"]?.textValue ?? "", function: values["function"]?.textValue ?? "skinFragment", data: data, snapshot: components.snapshot, now: now))
        default: return AnyView(EmptyView())
        }
    }

    /// Evaluates `glyphMotion` once per glyph. `glyph` carries index, count, char, word, line,
    /// start and end (seconds), age (seconds since the glyph's start), progress (0…1 through it)
    /// and lineAge. Lyric lines time glyphs by the sung words; plain text from when it last changed.
    private func glyphStyle(_ values: [String: SkinValue], text: String, lineIndex: Int?, lyricTime: Double, now: Double, fontSize: Double) -> SkinGlyphStyle? {
        let fallback = values["color"]?.colorValue ?? data.theme["theme.appForeground.primary"]?.colorValue
        let outline = SkinGlyphOutline(values["outline"], fallback: fallback)
        let extrude = SkinGlyphExtrude(values["extrude"], fallback: nil)
        var style = SkinGlyphStyle(outline: outline, extrude: extrude, padding: (outline?.width ?? 0) + (extrude?.depth ?? 0) + 1)
        guard let motion = node.properties["glyphMotion"] else { return outline == nil && extrude == nil ? nil : style }
        let characters = Array(text.filter { !$0.isNewline })
        guard configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full,
              !characters.isEmpty, characters.count <= 512 else { return style }
        var times = lineIndex.map { data.lyricsTimeline.glyphTimes(index: $0, text: String(characters)) } ?? []
        let clock: Double
        if lineIndex != nil {
            clock = lyricTime
        } else {
            clock = now
            let start = glyphClock.start(for: text + "\u{1F}" + (values["key"]?.textValue ?? ""), now: now)
            times = Array(repeating: (start: start, end: start, word: 0), count: characters.count)
        }
        if times.count != characters.count { times = Array(repeating: (start: clock, end: clock, word: 0), count: characters.count) }
        let lineStart = times.first?.start ?? clock
        var scope = context(now: now)
        var reach = 0.0, growth = 0.0
        style.transforms.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            let time = times[index]
            scope.locals["glyph"] = .record([
                "index": .number(Double(index)), "count": .number(Double(characters.count)), "char": .text(String(character)),
                "word": .number(Double(time.word)), "line": .number(Double(lineIndex ?? 0)),
                "start": .number(time.start), "end": .number(time.end), "age": .number(clock - time.start),
                "progress": .number(time.end > time.start ? ((clock - time.start) / (time.end - time.start)).clamped01 : (clock >= time.start ? 1 : 0)),
                "lineAge": .number(clock - lineStart),
            ])
            let transform = SkinGlyphTransform(motion.evaluate(scope))
            reach = max(reach, abs(transform.x) + abs(transform.split) + abs(transform.smearX) / 2,
                        abs(transform.y) + abs(transform.smearY) / 2, transform.blur * 3)
            growth = max(growth, transform.scale - 1, abs(transform.rotation) > 0.5 ? 0.5 : 0)
            style.transforms.append(transform)
        }
        style.padding += reach + growth * fontSize
        return style
    }

    /// A layer's camera for its positioned children. A per-frame camera is evaluated once per
    /// display frame by whichever child asks first; the layer itself stays off the timeline.
    private func cameraLink(now: Double) -> SkinCameraLink? {
        guard let property = node.camera else { return nil }
        let moves = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full
        guard property.tier == .frame, moves else {
            return SkinCameraLink(source: cameraSource, steady: SkinSceneCamera(property.evaluate(context(now: now))))
        }
        let view = self
        cameraSource.pausesWithPlayback = node.cameraPausesWithPlayback
        cameraSource.evaluate = { now in SkinSceneCamera(property.evaluate(view.context(now: now))) }
        return SkinCameraLink(source: cameraSource, steady: nil)
    }

    private func perform(_ event: String, now: Double, gesture: SkinValue? = nil) {
        SkinSceneActionRunner.run(node.actions[event] ?? [], context: context(now: Date.timeIntervalSinceReferenceDate, gesture: gesture), actions: actions)
    }

    private func gestureValue(_ value: DragGesture.Value, size: CGSize) -> SkinValue {
        .record(["x": .number(value.location.x), "y": .number(value.location.y),
                 "fractionX": .number((value.location.x / max(1, size.width)).clamped01), "fractionY": .number((value.location.y / max(1, size.height)).clamped01),
                 "translationX": .number(value.translation.width), "translationY": .number(value.translation.height)])
    }

    /// Sizes stay non-negative; `signed` positions may lie left of or above the layer.
    private func dimension(_ value: SkinValue, horizontal: Bool, signed: Bool = false) -> CGFloat? {
        let floor = signed ? -Double.infinity : 0
        if let number = value.numberValue { return CGFloat(max(floor, number)) }
        let text = value.textValue
        let viewport = live?.size ?? data.viewportSize
        let units: [(String, Double)] = [("vmin", min(viewport.width, viewport.height)), ("vmax", max(viewport.width, viewport.height)), ("vw", viewport.width), ("vh", viewport.height), ("%", horizontal ? size.width : size.height)]
        for (suffix, base) in units where text.hasSuffix(suffix) {
            if let number = Double(text.dropLast(suffix.count)) { return CGFloat(max(floor, base * number / 100)) }
        }
        return nil
    }

    private func applyKeyframes(_ values: inout [String: SkinValue], now: Double) {
        guard configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full,
              let keyframes = values["keyframes"] else { return }
        let duration = max(0.001, keyframes[member: "duration"].number(1))
        let elapsed = max(0, now - animationStart)
        let fraction = keyframes[member: "repeat"].isTruthy ? elapsed.truncatingRemainder(dividingBy: duration) / duration : min(1, elapsed / duration)
        guard case .record(let tracks) = keyframes[member: "tracks"] else { return }
        for (key, track) in tracks {
            let points = track.listValue
            guard !points.isEmpty else { continue }
            let position = fraction * Double(max(0, points.count - 1))
            let first = min(points.count - 1, Int(position)), second = min(points.count - 1, first + 1)
            let a = points[first].number(), b = points[second].number()
            values[key] = .number(a + (b - a) * (position - Double(first)))
        }
    }
}

func unitPoint(_ name: String) -> UnitPoint {
    switch name {
    case "topLeading": .topLeading
    case "top": .top
    case "topTrailing": .topTrailing
    case "leading": .leading
    case "trailing": .trailing
    case "bottomLeading": .bottomLeading
    case "bottom": .bottom
    case "bottomTrailing": .bottomTrailing
    default: .center
    }
}

private func alignment(_ name: String) -> Alignment {
    switch name {
    case "topLeading": .topLeading
    case "top": .top
    case "topTrailing": .topTrailing
    case "leading": .leading
    case "trailing": .trailing
    case "bottomLeading": .bottomLeading
    case "bottom": .bottom
    case "bottomTrailing": .bottomTrailing
    default: .center
    }
}

private func textAlignment(_ name: String) -> TextAlignment {
    switch name {
    case "center": .center
    case "trailing": .trailing
    default: .leading
    }
}

/// A scroll region that brings the repeat cell at `target` to its centre when the value changes.
private struct SkinSceneFollowingScroll<Content: View>: View {
    let target: Int?
    @ViewBuilder let content: () -> Content
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content() }
                .onChange(of: target, initial: true) { _, next in
                    guard let next, next >= 0 else { return }
                    let animation = motionPolicy.resolvedAnimation(for: motionTokens[.layout], accessibilityReduceMotion: accessibilityReduceMotion)
                    withAnimation(animation) { proxy.scrollTo(next, anchor: .center) }
                }
        }
    }
}

/// `stops` ({color, at}) when given, otherwise `colors` spaced evenly.
private func skinGradient(_ values: [String: SkinValue]) -> Gradient {
    let stops = (values["stops"]?.listValue ?? []).compactMap { stop -> Gradient.Stop? in
        guard let color = stop[member: "color"].colorValue else { return nil }
        return .init(color: color.swiftUIColor, location: stop[member: "at"].number().clamped01)
    }
    if !stops.isEmpty { return Gradient(stops: stops.sorted { $0.location < $1.location }) }
    return Gradient(colors: (values["colors"]?.listValue ?? []).compactMap { $0.colorValue?.swiftUIColor })
}

/// Size-derived viewport and host facts, computed with the size SwiftUI is laying out. The feeds
/// write the same facts after the update, which alone would leave units one size behind.
struct SkinLiveViewport: Equatable {
    let size: CGSize
    let facts: [String: SkinValue]

    init(size: CGSize, surface: SkinSurface, lyricsVisible: Bool, presentation: SkinPresentationPolicy) {
        self.size = size
        let layout = SkinHostLayout.frames(size: size, surface: surface, lyricsVisible: lyricsVisible, presentation: presentation)
        facts = [
            "viewport.width": .number(size.width), "viewport.height": .number(size.height),
            "viewport.w": .number(size.width), "viewport.h": .number(size.height),
            "viewport.min": .number(min(size.width, size.height)), "viewport.max": .number(max(size.width, size.height)),
            "viewport.aspect": .number(size.width / max(1, size.height)),
            "host.layout": SkinHostLayout.value(layout),
        ]
    }
}

extension EnvironmentValues {
    @Entry var skinSceneLiveViewport: SkinLiveViewport?
}

private func skinFontDesign(_ name: String) -> Font.Design {
    switch name {
    case "rounded": .rounded
    case "serif": .serif
    case "monospaced": .monospaced
    default: .default
    }
}

private func skinFontWeight(_ name: String) -> Font.Weight {
    switch name {
    case "ultralight": .ultraLight
    case "light": .light
    case "medium": .medium
    case "semibold": .semibold
    case "bold": .bold
    case "heavy": .heavy
    case "black": .black
    default: .regular
    }
}
