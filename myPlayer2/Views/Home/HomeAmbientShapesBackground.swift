//
//  HomeAmbientShapesBackground.swift
//  myPlayer2
//
//  Lightweight, non-interactive ambient shape layer for Home.
//
//  Architecture:
//    HomeAmbientShapesBackground is a thin SwiftUI `NSViewRepresentable`
//    whose only SwiftUI inputs are stable per-content values
//    (sourceColor / analysis / colorScheme / reduceMotion). All live
//    geometry and scroll-offset observation happens INSIDE the AppKit
//    `HomeAmbientRootView`, which subscribes directly to:
//      - `HomeWindowLayoutState.shared.geometryPublisher` (continuous
//        window/center geometry from the AppKit split view)
//      - `HomeAmbientMotionState.$scrollOffsetY` (Home ScrollView offset
//        published by `HomeVerticalScrollOffsetProbeView`)
//      - `BackgroundAnimationClock.shared.dotHighRatePublisher` for ambient
//        drift (shared 30Hz clock; same source the previous working build at
//        commit b473d4f used)
//
//    This means SwiftUI body re-evaluation is completely decoupled from
//    resize / sidebar-toggle / scroll ticks. The ambient layer keeps
//    repositioning shapes via CALayer transforms inside the AppKit view
//    without going through SwiftUI's diff path. Only an actual palette /
//    color-scheme change re-runs `updateNSView`.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class HomeAmbientMotionState: ObservableObject {
    @Published private(set) var scrollOffsetY: CGFloat = 0

    private let offsetEpsilon: CGFloat = 0.5

    func setScrollOffset(_ offset: CGFloat) {
        let next = max(0, offset)
        guard abs(scrollOffsetY - next) >= offsetEpsilon else { return }
        scrollOffsetY = next
    }
}

struct HomeAmbientShapesBackground: NSViewRepresentable {
    let motion: HomeAmbientMotionState
    let sourceColor: NSColor?
    let sourceAnalysis: ArtworkColorAnalysis?
    let colorScheme: ColorScheme
    let reduceMotion: Bool

    static func ambientBaseColorForStaticCache(colorScheme: ColorScheme) -> NSColor {
        HomeAmbientPalette.ambientBaseColor(from: nil, analysis: nil, colorScheme: colorScheme)
    }

    func makeNSView(context _: Context) -> HomeAmbientRootView {
        HomeAmbientRootView(motion: motion)
    }

    func updateNSView(_ nsView: HomeAmbientRootView, context _: Context) {
        nsView.update(
            motion: motion,
            sourceColor: sourceColor,
            sourceAnalysis: sourceAnalysis,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion
        )
    }
}

// MARK: - AppKit root view

@MainActor
final class HomeAmbientRootView: NSView {
    private struct Presentation {
        let id: Int
        let image: CGImage
        let color: NSColor
        let side: CGFloat
        let sideDirection: HomeAmbientShapeSpec.Side
        let sizeTier: HomeAmbientShapeSpec.SizeTier
        let boundaryOffsetX: CGFloat
        let isShape10: Bool
        let baseY: CGFloat
        var basePosition: CGPoint
        let baseRotationDegrees: Double
        let parallaxX: CGFloat
        let parallax: CGFloat
        let rotationPerPoint: CGFloat
        let rotationClampDegrees: CGFloat

        let ambientPhase: CGFloat
        let ambientSpeed: CGFloat
        let ambientAmplitudeX: CGFloat
        let ambientAmplitudeY: CGFloat
        let ambientRotationDegrees: CGFloat
        let ambientScaleAmount: CGFloat
    }

    private struct ShapeLayerPair {
        let container: CALayer
        let mask: CALayer
    }

    /// Rebuilding the full presentation array (specs, sizes, colors, layer
    /// images) is expensive. We cache the bucketed signature so continuous
    /// resize ticks that don't change the bucket only run the cheap
    /// reposition path (per-presentation basePosition + layer position).
    private struct LayoutSignature: Equatable {
        let viewportHeightBucket: Int   // /160 quantized
        let virtualHeightBucket: Int    // /240 quantized
        let centerWidthBucket: Int      // /16 quantized
        let mode: HomeLayoutMode
        let shapeFileSignature: Int
        let paletteSignature: PaletteSignature
        let colorScheme: ColorScheme
    }

    private struct PaletteSignature: Equatable {
        let sourceColorRGBA: UInt32
        let colorfulnessBits: UInt32
        let avgSaturationBits: UInt32
        let isEffectivelyMonochrome: Bool
    }

    private var motion: HomeAmbientMotionState
    private var motionSubscription: AnyCancellable?
    private var geometrySubscription: AnyCancellable?
    private var clockSubscription: AnyCancellable?
    private var holdsClockLease = false

    private var sourceColor: NSColor?
    private var sourceAnalysis: ArtworkColorAnalysis?
    private var colorScheme: ColorScheme = .light
    private var reduceMotion = false

    private var geometry: HomeWindowLayoutState.Geometry = .empty
    private var scrollOffsetY: CGFloat = 0
    private var lastLayoutSignature: LayoutSignature?
    private var hasPublishedFirstFrameLog = false

    private let baseLayer = CALayer()
    private var shapeLoadResult = BKThemeAssets.ShapeLoadResult(
        images: [],
        scaleByIndex: [:],
        edgePinnedIndices: []
    )
    private var presentations: [Presentation] = []
    private var layersByID: [Int: ShapeLayerPair] = [:]

    private let animationStartTime = CACurrentMediaTime()
    private var hasLoadedShapes = false

    private static let shapeMaxPixel = 768

    init(motion: HomeAmbientMotionState) {
        self.motion = motion
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.masksToBounds = true
        baseLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        baseLayer.backgroundColor = HomeAmbientPalette.ambientBaseColor(
            from: nil,
            analysis: nil,
            colorScheme: .light
        ).homeAmbientDeviceRGBCGColor
        layer?.addSublayer(baseLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Keep the base color layer flush with the view's bounds without
        // ever writing back to `frame` (which would fight SwiftUI's layout
        // pass and cause resize jitter). Shape layers are positioned in
        // window-content coordinates by `applyLayerTransforms`.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimationClock()
            geometrySubscription = nil
            motionSubscription = nil
        } else {
            loadShapesIfNeeded()
            subscribeToLayoutState()
            subscribeToMotion()
            // Pull the current published values explicitly. CurrentValueSubject
            // delivers asynchronously through `.receive(on: RunLoop.main)`, so
            // without these calls the layer would be empty for one extra
            // runloop tick on first mount.
            applyGeometryChange(HomeWindowLayoutState.shared.geometry)
            applyScrollOffset(motion.scrollOffsetY)
            startAnimationClockIfNeeded()
        }
    }

    func update(
        motion: HomeAmbientMotionState,
        sourceColor: NSColor?,
        sourceAnalysis: ArtworkColorAnalysis?,
        colorScheme: ColorScheme,
        reduceMotion: Bool
    ) {
        let motionChanged = self.motion !== motion
        self.motion = motion
        if motionChanged {
            subscribeToMotion()
            applyScrollOffset(motion.scrollOffsetY)
        }

        let paletteChanged = !colorsEqual(self.sourceColor, sourceColor)
            || self.sourceAnalysis != sourceAnalysis
            || self.colorScheme != colorScheme
        let reduceMotionChanged = self.reduceMotion != reduceMotion

        self.sourceColor = sourceColor
        self.sourceAnalysis = sourceAnalysis
        self.colorScheme = colorScheme
        self.reduceMotion = reduceMotion

        if paletteChanged {
            updateBaseLayerColor()
            rebuildOrReposition(for: geometry, forceFullRebuild: true)
        }
        if reduceMotionChanged {
            startAnimationClockIfNeeded()
            applyLayerTransforms()
        }
    }

    // MARK: - Subscriptions

    private func subscribeToLayoutState() {
        geometrySubscription = HomeWindowLayoutState.shared.geometryPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] geometry in
                self?.applyGeometryChange(geometry)
            }
    }

    private func subscribeToMotion() {
        motionSubscription = motion.$scrollOffsetY
            .receive(on: RunLoop.main)
            .sink { [weak self] offset in
                self?.applyScrollOffset(offset)
            }
    }

    // MARK: - Geometry / palette

    private func applyGeometryChange(_ next: HomeWindowLayoutState.Geometry) {
        guard next.hasValidLayout else { return }
        guard next != geometry else { return }
        geometry = next
        rebuildOrReposition(for: next, forceFullRebuild: false)
    }

    private func applyScrollOffset(_ offset: CGFloat) {
        let clamped = max(0, offset)
        guard abs(clamped - scrollOffsetY) >= 0.5 else { return }
        scrollOffsetY = clamped
        applyLayerTransforms()
    }

    private func updateBaseLayerColor() {
        let baseColor = HomeAmbientPalette.ambientBaseColor(
            from: sourceColor,
            analysis: sourceAnalysis,
            colorScheme: colorScheme
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.backgroundColor = baseColor.homeAmbientDeviceRGBCGColor
        CATransaction.commit()
    }

    // MARK: - Shape assets

    private func loadShapesIfNeeded() {
        guard !hasLoadedShapes else { return }
        hasLoadedShapes = true
        shapeLoadResult = BKThemeAssets.shared.shapes(maxPixel: Self.shapeMaxPixel)
        rebuildOrReposition(for: geometry, forceFullRebuild: true)
    }

    // MARK: - Presentation building / repositioning

    private func rebuildOrReposition(
        for geometry: HomeWindowLayoutState.Geometry,
        forceFullRebuild: Bool
    ) {
        guard geometry.hasValidLayout, !shapeLoadResult.images.isEmpty else {
            presentations = []
            lastLayoutSignature = nil
            removeAllShapeLayers()
            applyLayerTransforms()
            return
        }

        let signature = makeLayoutSignature(for: geometry)
        if !forceFullRebuild,
           let prev = lastLayoutSignature,
           prev == signature,
           !presentations.isEmpty {
            // Hot path: bucketed inputs unchanged, only continuous geometry
            // moved. Just slide the cached presentations to new positions and
            // re-apply layer transforms — no palette / spec / image work.
            repositionPresentations(for: geometry)
            applyLayerTransforms()
            return
        }

        lastLayoutSignature = signature
        rebuildPresentationsFully(for: geometry)
    }

    private func makeLayoutSignature(for geometry: HomeWindowLayoutState.Geometry) -> LayoutSignature {
        let viewportH = geometry.windowHeight
        let virtualH = max(viewportH * 2.6, viewportH + 1400)
        let centerW = geometry.centerWidth
        var fileHasher = Hasher()
        for name in shapeLoadResult.fileNames {
            fileHasher.combine(name)
        }
        return LayoutSignature(
            viewportHeightBucket: Int((viewportH / 160).rounded()),
            virtualHeightBucket: Int((virtualH / 240).rounded()),
            centerWidthBucket: Int((centerW / 16).rounded()),
            mode: layoutMode(for: centerW),
            shapeFileSignature: fileHasher.finalize(),
            paletteSignature: makePaletteSignature(),
            colorScheme: colorScheme
        )
    }

    private func makePaletteSignature() -> PaletteSignature {
        var rgba: UInt32 = 0
        if let rgb = sourceColor?.usingColorSpace(.deviceRGB) {
            rgba = (UInt32(min(max(rgb.redComponent, 0), 1) * 255) << 24)
                | (UInt32(min(max(rgb.greenComponent, 0), 1) * 255) << 16)
                | (UInt32(min(max(rgb.blueComponent, 0), 1) * 255) << 8)
                | UInt32(min(max(rgb.alphaComponent, 0), 1) * 255)
        }
        let colorfulness = sourceAnalysis?.colorfulness ?? 0
        let avgSaturation = sourceAnalysis?.avgSaturation ?? 0
        let mono = sourceAnalysis?.isEffectivelyMonochrome ?? false
        return PaletteSignature(
            sourceColorRGBA: rgba,
            colorfulnessBits: UInt32(min(max(colorfulness, 0), 1) * 1024),
            avgSaturationBits: UInt32(min(max(avgSaturation, 0), 1) * 1024),
            isEffectivelyMonochrome: mono
        )
    }

    private func rebuildPresentationsFully(for geometry: HomeWindowLayoutState.Geometry) {
        let palette = HomeAmbientPalette.palette(
            sourceColor: sourceColor,
            analysis: sourceAnalysis,
            colorScheme: colorScheme
        )
        let count = Self.shapeCount
        let viewportH = geometry.windowHeight
        let virtualH = max(viewportH * 2.6, viewportH + 1400)
        let centerW = geometry.centerWidth
        let mode = layoutMode(for: centerW)
        let layoutProgress = HomeAmbientPalette.layoutProgress(centerWidth: centerW)
        let wideExpansion = HomeAmbientPalette.wideExpansion(centerWidth: centerW)

        let specs = HomeAmbientShapeSpecCache.shared.specs(
            count: count,
            viewportHeight: viewportH,
            virtualHeight: virtualH,
            mode: mode,
            shapeFileNames: shapeLoadResult.fileNames
        )

        var built: [Presentation] = []
        built.reserveCapacity(specs.count)
        for spec in specs {
            guard !shapeLoadResult.images.isEmpty else { continue }
            let assetIndex = spec.assetIndex % shapeLoadResult.images.count
            let image = shapeLoadResult.images[assetIndex]
            let side = sideLength(
                for: spec,
                geometry: geometry,
                layoutProgress: layoutProgress,
                wideExpansion: wideExpansion
            )
            let position = basePosition(
                for: spec,
                side: side,
                geometry: geometry,
                layoutProgress: layoutProgress
            )
            let color: NSColor = {
                guard !palette.isEmpty else {
                    return colorScheme == .dark
                        ? NSColor(calibratedWhite: 0.42, alpha: 1)
                        : NSColor(calibratedWhite: 0.78, alpha: 1)
                }
                return palette[spec.colorIndex % palette.count]
            }()

            built.append(
                Presentation(
                    id: spec.id,
                    image: image,
                    color: color,
                    side: side,
                    sideDirection: spec.side,
                    sizeTier: spec.sizeTier,
                    boundaryOffsetX: spec.boundaryOffsetX,
                    isShape10: isShape10(spec),
                    baseY: spec.baseY,
                    basePosition: position,
                    baseRotationDegrees: spec.baseRotationDegrees,
                    parallaxX: spec.parallaxX,
                    parallax: spec.parallax,
                    rotationPerPoint: spec.rotationPerPoint,
                    rotationClampDegrees: spec.rotationClampDegrees,
                    ambientPhase: CGFloat((spec.id * 37) % 360) * .pi / 180,
                    ambientSpeed: 0.10 + CGFloat((spec.id * 11) % 7) * 0.012,
                    ambientAmplitudeX: ambientAmplitudeX(forSpec: spec),
                    ambientAmplitudeY: 24 + CGFloat((spec.id * 7) % 9) * 3.5,
                    ambientRotationDegrees: 4.5 + CGFloat((spec.id * 13) % 6) * 1.2,
                    ambientScaleAmount: 0.026 + CGFloat((spec.id * 17) % 5) * 0.005
                )
            )
        }

        presentations = built
        syncShapeLayers()
        applyLayerTransforms()
        startAnimationClockIfNeeded()
        if !hasPublishedFirstFrameLog {
            hasPublishedFirstFrameLog = true
            Log.debug(
                "[HomeAmbient] First full presentation rebuild: shapes=\(built.count) viewport=\(Int(viewportH)) center=\(Int(centerW))",
                category: .ui
            )
        }
    }

    private func repositionPresentations(for geometry: HomeWindowLayoutState.Geometry) {
        let centerW = geometry.centerWidth
        let layoutProgress = HomeAmbientPalette.layoutProgress(centerWidth: centerW)
        for index in presentations.indices {
            presentations[index].basePosition = basePosition(
                forPresentation: presentations[index],
                geometry: geometry,
                layoutProgress: layoutProgress
            )
        }
    }

    private func basePosition(
        forPresentation presentation: Presentation,
        geometry: HomeWindowLayoutState.Geometry,
        layoutProgress: CGFloat
    ) -> CGPoint {
        let half = presentation.side * 0.5
        let isUltraShape10 = presentation.sizeTier == .ultra && presentation.isShape10
        let boundary: CGFloat = presentation.sideDirection == .left
            ? geometry.centerMinXInWindow
            : geometry.centerMaxXInWindow
        let fluidBoundaryScale = 0.48 + layoutProgress * 0.52

        let boundaryOffsetX: CGFloat
        if isUltraShape10 {
            let outwardDistance = max(abs(presentation.boundaryOffsetX), presentation.side * 0.70)
            boundaryOffsetX = presentation.sideDirection == .left ? -outwardDistance : outwardDistance
        } else {
            boundaryOffsetX = presentation.boundaryOffsetX * fluidBoundaryScale
        }

        let x = clamp(
            boundary + boundaryOffsetX,
            min: -half * (isUltraShape10 ? 1.15 : 0.72),
            max: geometry.windowWidth + half * (isUltraShape10 ? 1.15 : 0.72)
        )

        return CGPoint(x: x, y: presentation.baseY)
    }

    private func ambientAmplitudeX(forSpec spec: HomeAmbientShapeSpec) -> CGFloat {
        let magnitude = 24 + CGFloat((spec.id * 5) % 6) * 4.5
        return spec.side == .left ? magnitude : -magnitude
    }

    private static var shapeCount: Int {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 12 : 18
    }

    private func layoutMode(for centerWidth: CGFloat) -> HomeLayoutMode {
        if centerWidth >= 980 { return .wide }
        if centerWidth >= 720 { return .medium }
        if centerWidth >= 560 { return .compact }
        return .narrow
    }

    private func sideLength(
        for spec: HomeAmbientShapeSpec,
        geometry: HomeWindowLayoutState.Geometry,
        layoutProgress: CGFloat,
        wideExpansion: CGFloat
    ) -> CGFloat {
        guard geometry.hasValidLayout else { return 0 }
        let assetIndex = shapeLoadResult.images.isEmpty
            ? spec.assetIndex
            : spec.assetIndex % shapeLoadResult.images.count
        let assetMultiplier: CGFloat = switch spec.sizeTier {
        case .small, .medium:
            min(1.18, max(1.0, shapeLoadResult.scaleByIndex[assetIndex] ?? 1.0))
        case .large, .ultra:
            1.0
        }

        let fluidShapeScale = 0.72 + layoutProgress * 0.28 + wideExpansion * 0.08
        let minSide = lerp(54, 70, layoutProgress)
        let maxSide = lerp(680, 980, min(1, layoutProgress + wideExpansion * 0.45))

        return clamp(spec.nominalSide * assetMultiplier * fluidShapeScale, min: minSide, max: maxSide)
    }

    private func basePosition(
        for spec: HomeAmbientShapeSpec,
        side: CGFloat,
        geometry: HomeWindowLayoutState.Geometry,
        layoutProgress: CGFloat
    ) -> CGPoint {
        let centerMinX = geometry.centerMinXInWindow
        let centerMaxX = geometry.centerMaxXInWindow
        let half = side * 0.5
        let isUltraShape10 = spec.sizeTier == .ultra && isShape10(spec)
        let boundary: CGFloat = spec.side == .left ? centerMinX : centerMaxX
        let fluidBoundaryScale = 0.48 + layoutProgress * 0.52

        let boundaryOffsetX: CGFloat
        if isUltraShape10 {
            let outwardDistance = max(abs(spec.boundaryOffsetX), side * 0.70)
            boundaryOffsetX = spec.side == .left ? -outwardDistance : outwardDistance
        } else {
            boundaryOffsetX = spec.boundaryOffsetX * fluidBoundaryScale
        }

        let x = clamp(
            boundary + boundaryOffsetX,
            min: -half * (isUltraShape10 ? 1.15 : 0.72),
            max: geometry.windowWidth + half * (isUltraShape10 ? 1.15 : 0.72)
        )

        return CGPoint(x: x, y: spec.baseY)
    }

    private func isShape10(_ spec: HomeAmbientShapeSpec) -> Bool {
        guard !shapeLoadResult.fileNames.isEmpty else { return false }
        let assetIndex = spec.assetIndex % shapeLoadResult.fileNames.count
        return shapeLoadResult.fileNames[assetIndex].caseInsensitiveCompare("shape10.png") == .orderedSame
    }

    // MARK: - Layer sync

    private func removeAllShapeLayers() {
        for pair in layersByID.values {
            pair.container.removeFromSuperlayer()
        }
        layersByID.removeAll(keepingCapacity: true)
    }

    private func syncShapeLayers() {
        guard let rootLayer = layer else { return }
        let activeIDs = Set(presentations.map(\.id))
        for (id, pair) in layersByID where !activeIDs.contains(id) {
            pair.container.removeFromSuperlayer()
            layersByID[id] = nil
        }

        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for presentation in presentations {
            let pair = layerPair(for: presentation, in: rootLayer)
            let bounds = CGRect(x: 0, y: 0, width: presentation.side, height: presentation.side)
            pair.container.contentsScale = backingScale
            pair.container.backgroundColor = presentation.color.homeAmbientDeviceRGBCGColor
            pair.container.bounds = bounds
            pair.mask.contentsScale = backingScale
            pair.mask.contents = presentation.image
            pair.mask.contentsGravity = .resizeAspect
            pair.mask.minificationFilter = .linear
            pair.mask.magnificationFilter = .linear
            pair.mask.frame = bounds
        }

        CATransaction.commit()
    }

    private func layerPair(
        for presentation: Presentation,
        in rootLayer: CALayer
    ) -> ShapeLayerPair {
        if let existing = layersByID[presentation.id] {
            return existing
        }
        let container = CALayer()
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.masksToBounds = false
        container.allowsEdgeAntialiasing = true
        container.minificationFilter = .linear
        container.magnificationFilter = .linear

        let mask = CALayer()
        mask.anchorPoint = CGPoint(x: 0, y: 0)
        container.mask = mask
        rootLayer.addSublayer(container)
        let pair = ShapeLayerPair(container: container, mask: mask)
        layersByID[presentation.id] = pair
        return pair
    }

    // MARK: - Animation

    /// Subscribe to the shared 30Hz `BackgroundAnimationClock` so ambient
    /// drift advances on every gate tick. We keep this path instead of
    /// `NSView.displayLink(target:selector:)` because the latter shadows the
    /// inherited `displayLink` symbol on the subclass and was not firing on
    /// SwiftUI-hosted instances during testing — the shared clock is what
    /// the previous working build used (see commit b473d4f).
    private func startAnimationClockIfNeeded() {
        guard window != nil, !presentations.isEmpty, !reduceMotion else {
            stopAnimationClock()
            return
        }
        guard clockSubscription == nil else { return }
        clockSubscription = BackgroundAnimationClock.shared.dotHighRatePublisher
            .sink { [weak self] in
                self?.applyLayerTransforms()
            }
        if !holdsClockLease {
            BackgroundAnimationClock.shared.acquire()
            holdsClockLease = true
        }
    }

    private func stopAnimationClock() {
        clockSubscription?.cancel()
        clockSubscription = nil
        if holdsClockLease {
            BackgroundAnimationClock.shared.release()
            holdsClockLease = false
        }
    }

    private func applyLayerTransforms() {
        guard !presentations.isEmpty else { return }
        let elapsed = CGFloat(CACurrentMediaTime() - animationStartTime)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for presentation in presentations {
            guard let pair = layersByID[presentation.id] else { continue }
            let scroll = scrollTransform(for: presentation, scrollOffsetY: scrollOffsetY)
            let ambient = ambientTransform(for: presentation, elapsed: elapsed)

            pair.container.position = CGPoint(
                x: presentation.basePosition.x + scroll.x + ambient.x,
                y: presentation.basePosition.y + scroll.y + ambient.y
            )
            var transform = CATransform3DMakeRotation(
                CGFloat((presentation.baseRotationDegrees + scroll.rotationDegrees) * .pi / 180)
                    + ambient.rotationRadians,
                0,
                0,
                1
            )
            transform = CATransform3DScale(transform, ambient.scale, ambient.scale, 1)
            pair.container.transform = transform
        }

        CATransaction.commit()
    }

    private func ambientTransform(
        for presentation: Presentation,
        elapsed: CGFloat
    ) -> (x: CGFloat, y: CGFloat, rotationRadians: CGFloat, scale: CGFloat) {
        guard !reduceMotion else { return (0, 0, 0, 1) }
        let phase = presentation.ambientPhase + elapsed * presentation.ambientSpeed
        return (
            x: sin(phase) * presentation.ambientAmplitudeX,
            y: cos(phase * 0.82) * presentation.ambientAmplitudeY,
            rotationRadians: sin(phase * 0.64) * presentation.ambientRotationDegrees * .pi / 180,
            scale: 1 + sin(phase * 0.48) * presentation.ambientScaleAmount
        )
    }

    private func scrollTransform(
        for presentation: Presentation,
        scrollOffsetY: CGFloat
    ) -> (x: CGFloat, y: CGFloat, rotationDegrees: Double) {
        guard !reduceMotion else { return (0, 0, 0) }
        let virtualHeight = max(geometry.windowHeight * 2.6, geometry.windowHeight + 1400)
        return (
            x: clamp(scrollOffsetY * presentation.parallaxX, min: -90, max: 90),
            y: clamp(-scrollOffsetY * presentation.parallax, min: -virtualHeight, max: virtualHeight),
            rotationDegrees: Double(
                clamp(
                    scrollOffsetY * presentation.rotationPerPoint,
                    min: -presentation.rotationClampDegrees,
                    max: presentation.rotationClampDegrees
                )
            )
        )
    }

    private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(a), .some(b)):
            return a.isEqual(b)
        default:
            return false
        }
    }
}

// MARK: - Palette helpers

private enum HomeAmbientPalette {
    static func ambientBaseColor(
        from source: NSColor?,
        analysis: ArtworkColorAnalysis?,
        colorScheme: ColorScheme
    ) -> NSColor {
        guard let source else {
            return colorScheme == .dark
                ? NSColor(calibratedHue: 0.10, saturation: 0.14, brightness: 0.10, alpha: 1)
                : .white
        }
        guard let rgb = source.usingColorSpace(.deviceRGB) else {
            return colorScheme == .dark
                ? NSColor(calibratedHue: 0.10, saturation: 0.14, brightness: 0.10, alpha: 1)
                : .white
        }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        if colorScheme == .dark {
            let lowColor = analysis?.isEffectivelyMonochrome
                ?? (saturation < 0.12)
            let satMin: CGFloat = lowColor ? 0.03 : 0.10
            let satMax: CGFloat = lowColor ? 0.09 : 0.22
            return NSColor(
                calibratedHue: hue,
                saturation: clamp(saturation * 0.30, min: satMin, max: satMax),
                brightness: clamp(brightness * 0.18, min: 0.07, max: 0.13),
                alpha: 1
            )
        }

        guard let hsl = hslComponents(from: source) else {
            return .white
        }
        return rgbColorFromHsl(
            h: hsl.h,
            s: clamp(hsl.s * 0.16, min: 0.05, max: 0.13),
            l: clamp(0.94 + hsl.l * 0.03, min: 0.93, max: 0.97)
        )
    }

    static func palette(
        sourceColor: NSColor?,
        analysis: ArtworkColorAnalysis?,
        colorScheme: ColorScheme
    ) -> [NSColor] {
        if let sourceColor {
            return makePalette(from: sourceColor, analysis: analysis, colorScheme: colorScheme)
        }
        return fallbackPalette(colorScheme: colorScheme)
    }

    static func layoutProgress(centerWidth: CGFloat) -> CGFloat {
        let width = max(centerWidth, 520)
        let raw = clamp((width - 560) / 620, min: 0, max: 1)
        return raw * raw * (3 - 2 * raw)
    }

    static func wideExpansion(centerWidth: CGFloat) -> CGFloat {
        let width = max(centerWidth, 520)
        let raw = clamp((width - 1180) / 520, min: 0, max: 1)
        return raw * raw * (3 - 2 * raw)
    }

    private static func makePalette(
        from source: NSColor,
        analysis: ArtworkColorAnalysis?,
        colorScheme: ColorScheme
    ) -> [NSColor] {
        guard let hsl = hslComponents(from: source) else {
            return fallbackPalette(colorScheme: colorScheme)
        }

        let isDark = colorScheme == .dark
        let colorfulness = analysis?.colorfulness ?? hsl.s
        let avgSaturation = analysis?.avgSaturation ?? hsl.s
        let isLowColor = analysis?.isEffectivelyMonochrome
            ?? (colorfulness < 0.12 || avgSaturation < 0.12)

        let targetSaturation: CGFloat
        if isDark {
            if isLowColor {
                targetSaturation = clamp(hsl.s * 0.42, min: 0.045, max: 0.13)
            } else {
                let floor = colorfulness >= 0.24 ? 0.19 : 0.13
                let colorfulnessLift = colorfulness * 0.36
                targetSaturation = clamp(
                    max(hsl.s * 0.72, colorfulnessLift),
                    min: floor,
                    max: 0.38
                )
            }
        } else {
            if isLowColor {
                targetSaturation = clamp(hsl.s * 0.34, min: 0.045, max: 0.14)
            } else {
                targetSaturation = clamp(
                    max(hsl.s * 0.48, colorfulness * 0.22),
                    min: 0.08,
                    max: 0.25
                )
            }
        }

        let targetLightness: CGFloat = isDark
            ? clamp(hsl.l * 0.54 + 0.05, min: 0.16, max: 0.30)
            : clamp(hsl.l + 0.28, min: 0.66, max: 0.84)

        let variants: [(hue: CGFloat, saturation: CGFloat, lightness: CGFloat)] = [
            (0, 0.00, 0.00),
            (24, -0.02, 0.04),
            (-18, 0.02, -0.03),
            (46, -0.04, 0.01),
            (-38, 0.01, 0.05),
            (68, -0.03, -0.02),
        ]

        return variants.map { variant in
            rgbColorFromHsl(
                h: hsl.h + variant.hue,
                s: clamp(
                    targetSaturation + variant.saturation,
                    min: isLowColor ? 0.035 : 0.06,
                    max: isDark ? (isLowColor ? 0.14 : 0.40) : (isLowColor ? 0.16 : 0.26)
                ),
                l: clamp(
                    targetLightness + variant.lightness,
                    min: isDark ? 0.14 : 0.64,
                    max: isDark ? 0.33 : 0.86
                )
            )
        }
    }

    private static func fallbackPalette(colorScheme: ColorScheme) -> [NSColor] {
        if colorScheme == .dark {
            return [
                NSColor(calibratedRed: 0.34, green: 0.52, blue: 0.51, alpha: 1),
                NSColor(calibratedRed: 0.38, green: 0.47, blue: 0.60, alpha: 1),
                NSColor(calibratedRed: 0.51, green: 0.42, blue: 0.55, alpha: 1),
                NSColor(calibratedRed: 0.46, green: 0.52, blue: 0.38, alpha: 1),
                NSColor(calibratedRed: 0.56, green: 0.45, blue: 0.38, alpha: 1),
            ]
        }
        return [
            NSColor(calibratedRed: 0.72, green: 0.78, blue: 0.70, alpha: 1),
            NSColor(calibratedRed: 0.68, green: 0.75, blue: 0.80, alpha: 1),
            NSColor(calibratedRed: 0.78, green: 0.69, blue: 0.67, alpha: 1),
            NSColor(calibratedRed: 0.80, green: 0.75, blue: 0.65, alpha: 1),
            NSColor(calibratedRed: 0.74, green: 0.70, blue: 0.78, alpha: 1),
        ]
    }

    private static func hslComponents(from color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        let r = clamp(rgb.redComponent, min: 0, max: 1)
        let g = clamp(rgb.greenComponent, min: 0, max: 1)
        let b = clamp(rgb.blueComponent, min: 0, max: 1)

        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) * 0.5

        guard delta > 0.000_001 else {
            return (0, 0, lightness)
        }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        let hue: CGFloat
        if maxValue == r {
            hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxValue == g {
            hue = 60 * (((b - r) / delta) + 2)
        } else {
            hue = 60 * (((r - g) / delta) + 4)
        }

        return (hue < 0 ? hue + 360 : hue, saturation, lightness)
    }

    private static func rgbColorFromHsl(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let normalizedHue = ((h.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((normalizedHue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c * 0.5

        let components: (CGFloat, CGFloat, CGFloat)
        switch normalizedHue {
        case 0..<60:
            components = (c, x, 0)
        case 60..<120:
            components = (x, c, 0)
        case 120..<180:
            components = (0, c, x)
        case 180..<240:
            components = (0, x, c)
        case 240..<300:
            components = (x, 0, c)
        default:
            components = (c, 0, x)
        }

        return NSColor(
            calibratedRed: clamp(components.0 + m, min: 0, max: 1),
            green: clamp(components.1 + m, min: 0, max: 1),
            blue: clamp(components.2 + m, min: 0, max: 1),
            alpha: 1
        )
    }
}

private extension NSColor {
    var homeAmbientDeviceRGBCGColor: CGColor {
        (usingColorSpace(.deviceRGB) ?? self).cgColor
    }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * clamp(t, min: 0, max: 1)
}

// MARK: - Spec generation (unchanged geometry / RNG behavior)

private final class HomeAmbientShapeSpecCache {
    static let shared = HomeAmbientShapeSpecCache()

    private let lock = NSLock()
    private var specsByKey: [Key: [HomeAmbientShapeSpec]] = [:]

    func specs(
        count: Int,
        viewportHeight: CGFloat,
        virtualHeight: CGFloat,
        mode: HomeLayoutMode,
        shapeFileNames: [String]
    ) -> [HomeAmbientShapeSpec] {
        let key = Key(
            count: count,
            viewportHeightBucket: Int((viewportHeight / 160).rounded()),
            virtualHeightBucket: Int((virtualHeight / 240).rounded()),
            mode: mode,
            shapeFileNames: shapeFileNames
        )

        lock.lock()
        if let cached = specsByKey[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = HomeAmbientShapeSpec.makeStableSet(
            count: count,
            viewportHeight: CGFloat(key.viewportHeightBucket) * 160,
            virtualHeight: CGFloat(key.virtualHeightBucket) * 240,
            mode: mode,
            shapeFileNames: shapeFileNames
        )

        lock.lock()
        if specsByKey.count > 24 {
            specsByKey.removeAll(keepingCapacity: true)
        }
        specsByKey[key] = built
        lock.unlock()
        return built
    }

    private struct Key: Hashable {
        let count: Int
        let viewportHeightBucket: Int
        let virtualHeightBucket: Int
        let mode: HomeLayoutMode
        let shapeFileNames: [String]
    }
}

struct HomeAmbientShapeSpec: Identifiable {
    enum Side {
        case left
        case right
    }

    enum SizeTier {
        case small
        case medium
        case large
        case ultra
    }

    let id: Int
    let assetIndex: Int
    let colorIndex: Int
    let side: Side
    let sizeTier: SizeTier
    let boundaryOffsetX: CGFloat
    let baseY: CGFloat
    let nominalSide: CGFloat
    let baseRotationDegrees: Double
    let parallaxX: CGFloat
    let parallax: CGFloat
    let rotationPerPoint: CGFloat
    let rotationClampDegrees: CGFloat

    static func makeStableSet(
        count: Int,
        viewportHeight: CGFloat,
        virtualHeight: CGFloat,
        mode: HomeLayoutMode,
        shapeFileNames: [String]
    ) -> [HomeAmbientShapeSpec] {
        var rng = HomeAmbientRandom(seed: 0x486F_6D65_5368_6170)
        let catalog = HomeAmbientShapeAssetCatalog(fileNames: shapeFileNames)
        var assetPicker = HomeAmbientShapeAssetPicker(catalog: catalog)
        let visibleCount = min(count, initialVisibleCount(for: count))
        let visibleLeftCount = (visibleCount + 1) / 2
        let visibleRightCount = visibleCount / 2
        let remainingCount = count - visibleCount
        let remainingLeftCount = (remainingCount + 1) / 2
        let remainingRightCount = remainingCount / 2
        let visibleYLower = -viewportHeight * 0.25
        let visibleYUpper = viewportHeight * 1.05
        let laterYLower = viewportHeight * 1.12
        let laterYUpper = virtualHeight

        var nextID = 0
        var specs: [HomeAmbientShapeSpec] = []
        specs.reserveCapacity(count)
        var forcedUltraIDs = Set<Int>()
        if catalog.hasUltra, count > 0 {
            forcedUltraIDs.insert(rng.nextInt(in: 0...(count - 1)))
        }

        let visibleLeft = makeSideSpecs(
            side: .left,
            startID: nextID,
            count: visibleLeftCount,
            yLower: visibleYLower,
            yUpper: visibleYUpper,
            viewportHeight: viewportHeight,
            mode: mode,
            existingSpecs: specs,
            previous: nil,
            forcedUltraIDs: forcedUltraIDs,
            rng: &rng,
            assetPicker: &assetPicker
        )
        nextID += visibleLeftCount
        specs += visibleLeft

        let visibleRight = makeSideSpecs(
            side: .right,
            startID: nextID,
            count: visibleRightCount,
            yLower: visibleYLower,
            yUpper: visibleYUpper,
            viewportHeight: viewportHeight,
            mode: mode,
            existingSpecs: specs,
            previous: nil,
            forcedUltraIDs: forcedUltraIDs,
            rng: &rng,
            assetPicker: &assetPicker
        )
        nextID += visibleRightCount
        specs += visibleRight

        let laterLeft = makeSideSpecs(
            side: .left,
            startID: nextID,
            count: remainingLeftCount,
            yLower: laterYLower,
            yUpper: laterYUpper,
            viewportHeight: viewportHeight,
            mode: mode,
            existingSpecs: specs,
            previous: visibleLeft.last,
            forcedUltraIDs: forcedUltraIDs,
            rng: &rng,
            assetPicker: &assetPicker
        )
        nextID += remainingLeftCount
        specs += laterLeft

        let laterRight = makeSideSpecs(
            side: .right,
            startID: nextID,
            count: remainingRightCount,
            yLower: laterYLower,
            yUpper: laterYUpper,
            viewportHeight: viewportHeight,
            mode: mode,
            existingSpecs: specs,
            previous: visibleRight.last,
            forcedUltraIDs: forcedUltraIDs,
            rng: &rng,
            assetPicker: &assetPicker
        )
        specs += laterRight

        return specs.sorted { $0.id < $1.id }
    }

    private static func makeSideSpecs(
        side: Side,
        startID: Int,
        count: Int,
        yLower: CGFloat,
        yUpper: CGFloat,
        viewportHeight: CGFloat,
        mode: HomeLayoutMode,
        existingSpecs: [HomeAmbientShapeSpec],
        previous: HomeAmbientShapeSpec?,
        forcedUltraIDs: Set<Int>,
        rng: inout HomeAmbientRandom,
        assetPicker: inout HomeAmbientShapeAssetPicker
    ) -> [HomeAmbientShapeSpec] {
        guard count > 0 else { return [] }

        let bandHeight = max(160, (yUpper - yLower) / CGFloat(count))
        var previousInSide = previous
        var specs: [HomeAmbientShapeSpec] = []
        specs.reserveCapacity(count)

        for sideIndex in 0..<count {
            let id = startID + sideIndex
            let spec = makeNonRepeatingSpec(
                id: id,
                side: side,
                sideIndex: sideIndex,
                yLower: yLower,
                yUpper: yUpper,
                bandHeight: bandHeight,
                viewportHeight: viewportHeight,
                mode: mode,
                existingSpecs: existingSpecs + specs,
                previousInSide: previousInSide,
                forcedUltraIDs: forcedUltraIDs,
                rng: &rng,
                assetPicker: &assetPicker
            )
            specs.append(spec)
            previousInSide = spec
        }
        return specs
    }

    private static func makeNonRepeatingSpec(
        id: Int,
        side: Side,
        sideIndex: Int,
        yLower: CGFloat,
        yUpper: CGFloat,
        bandHeight: CGFloat,
        viewportHeight: CGFloat,
        mode: HomeLayoutMode,
        existingSpecs: [HomeAmbientShapeSpec],
        previousInSide: HomeAmbientShapeSpec?,
        forcedUltraIDs: Set<Int>,
        rng: inout HomeAmbientRandom,
        assetPicker: inout HomeAmbientShapeAssetPicker
    ) -> HomeAmbientShapeSpec {
        var fallback: HomeAmbientShapeSpec?

        for attempt in 0..<6 {
            let asset = assetPicker.next(forceUltra: forcedUltraIDs.contains(id), rng: &rng)
            let sizeSpec = randomSize(assetKind: asset.kind, mode: mode, rng: &rng)
            let baseY = randomBaseY(
                sideIndex: sideIndex,
                size: sizeSpec.side,
                yLower: yLower,
                yUpper: yUpper,
                bandHeight: bandHeight,
                previous: previousInSide,
                rng: &rng
            )
            let rotationFactor = randomRotationFactor(sizeTier: sizeSpec.tier, rng: &rng)
            let spec = HomeAmbientShapeSpec(
                id: id,
                assetIndex: asset.index,
                colorIndex: id + rng.nextInt(in: 0...3),
                side: side,
                sizeTier: sizeSpec.tier,
                boundaryOffsetX: randomBoundaryOffset(side: side, sizeTier: sizeSpec.tier, mode: mode, rng: &rng),
                baseY: baseY,
                nominalSide: sizeSpec.side,
                baseRotationDegrees: randomBaseRotation(sizeTier: sizeSpec.tier, rng: &rng),
                parallaxX: CGFloat(rng.next(in: -0.07...0.07)),
                parallax: randomParallax(sizeTier: sizeSpec.tier, rng: &rng),
                rotationPerPoint: rotationFactor,
                rotationClampDegrees: rotationClamp(sizeTier: sizeSpec.tier)
            )

            fallback = spec
            if attempt == 5 || !hasNearSimilarDuplicate(spec, in: existingSpecs, viewportHeight: viewportHeight) {
                return spec
            }
        }

        return fallback ?? HomeAmbientShapeSpec(
            id: id,
            assetIndex: 0,
            colorIndex: id,
            side: side,
            sizeTier: .small,
            boundaryOffsetX: 0,
            baseY: yLower + CGFloat(sideIndex) * bandHeight,
            nominalSide: minimumFallbackSide(for: mode),
            baseRotationDegrees: 0,
            parallaxX: 0,
            parallax: 0.3,
            rotationPerPoint: 0,
            rotationClampDegrees: 0
        )
    }

    private static func hasNearSimilarDuplicate(
        _ spec: HomeAmbientShapeSpec,
        in existingSpecs: [HomeAmbientShapeSpec],
        viewportHeight: CGFloat
    ) -> Bool {
        existingSpecs.contains { other in
            guard other.assetIndex == spec.assetIndex else { return false }
            guard abs(other.baseY - spec.baseY) < viewportHeight * 0.9 else { return false }
            let ratio = spec.nominalSide / max(other.nominalSide, 1)
            return ratio >= 0.75 && ratio <= 1.33
        }
    }

    private static func minimumFallbackSide(for mode: HomeLayoutMode) -> CGFloat {
        switch mode {
        case .wide:
            return 120
        case .medium:
            return 110
        case .compact:
            return 96
        case .narrow:
            return 84
        }
    }

    private static func initialVisibleCount(for count: Int) -> Int {
        if count >= 16 {
            return 8
        }
        if count >= 12 {
            return 7
        }
        return min(count, 6)
    }

    private static func randomBaseY(
        sideIndex: Int,
        size: CGFloat,
        yLower: CGFloat,
        yUpper: CGFloat,
        bandHeight: CGFloat,
        previous: HomeAmbientShapeSpec?,
        rng: inout HomeAmbientRandom
    ) -> CGFloat {
        let bandStart = yLower + CGFloat(sideIndex) * bandHeight
        let bandEnd = min(yUpper, bandStart + bandHeight)
        let minimumGap = previous.map { min($0.nominalSide, size) * 0.45 + 80 } ?? 0

        for _ in 0..<8 {
            let candidate = CGFloat(rng.next(in: Double(bandStart)...Double(max(bandStart, bandEnd))))
            guard let previous else { return candidate }
            if candidate - previous.baseY >= minimumGap {
                return candidate
            }
        }

        if let previous {
            return min(yUpper, max(bandStart, previous.baseY + minimumGap))
        }
        return (bandStart + bandEnd) * 0.5
    }

    private static func randomSize(
        assetKind: HomeAmbientShapeAssetKind,
        mode: HomeLayoutMode,
        rng: inout HomeAmbientRandom
    ) -> (side: CGFloat, tier: SizeTier) {
        let roll = rng.next(in: 0.0...1.0)
        let raw: CGFloat
        let tier: SizeTier

        switch assetKind {
        case .ultra:
            tier = .ultra
            raw = CGFloat(rng.next(in: ultraRawRange(for: mode)))
        case .featuredLarge:
            tier = .large
            raw = CGFloat(rng.next(in: featuredLargeRawRange(for: mode)))
        case .normal:
            if roll < 0.54 {
                tier = .small
                raw = CGFloat(rng.next(in: 120...210))
            } else if roll < 0.88 {
                tier = .medium
                raw = CGFloat(rng.next(in: 220...360))
            } else {
                tier = .large
                raw = CGFloat(rng.next(in: 380...500))
            }
        }

        let scaled = raw * sizeScale(for: mode)
        if tier == .ultra, mode == .compact || mode == .narrow {
            return (clamp(scaled, min: 520, max: 680), tier)
        }
        if assetKind == .featuredLarge, mode == .compact || mode == .narrow {
            return (clamp(scaled, min: 320, max: 520), tier)
        }
        return (scaled, tier)
    }

    private static func ultraRawRange(for mode: HomeLayoutMode) -> ClosedRange<Double> {
        switch mode {
        case .wide:
            return 620...920
        case .medium:
            return 620...860
        case .compact, .narrow:
            return 520...680
        }
    }

    private static func featuredLargeRawRange(for mode: HomeLayoutMode) -> ClosedRange<Double> {
        switch mode {
        case .wide:
            return 380...680
        case .medium:
            return 380...620
        case .compact, .narrow:
            return 320...520
        }
    }

    private static func sizeScale(for mode: HomeLayoutMode) -> CGFloat {
        switch mode {
        case .wide:
            return 1.0
        case .medium:
            return 0.92
        case .compact:
            return 0.82
        case .narrow:
            return 0.72
        }
    }

    private static func randomBoundaryOffset(
        side: Side,
        sizeTier: SizeTier,
        mode: HomeLayoutMode,
        rng: inout HomeAmbientRandom
    ) -> CGFloat {
        let scale: CGFloat
        switch mode {
        case .wide:
            scale = 1.0
        case .medium:
            scale = 0.84
        case .compact:
            scale = 0.66
        case .narrow:
            scale = 0.48
        }

        let isUltra = sizeTier == .ultra
        let range: ClosedRange<Double>
        switch (side, isUltra) {
        case (.left, true):
            range = Double(-500 * scale)...Double(-130 * scale)
        case (.left, false):
            range = Double(-210 * scale)...Double(135 * scale)
        case (.right, true):
            range = Double(130 * scale)...Double(500 * scale)
        case (.right, false):
            range = Double(-135 * scale)...Double(210 * scale)
        }
        return CGFloat(rng.next(in: range))
    }

    private static func randomBaseRotation(
        sizeTier: SizeTier,
        rng: inout HomeAmbientRandom
    ) -> Double {
        if sizeTier == .ultra {
            return rng.next(in: -48...48)
        }
        return rng.next(in: -70...70)
    }

    private static func randomParallax(sizeTier: SizeTier, rng: inout HomeAmbientRandom) -> CGFloat {
        switch sizeTier {
        case .small:
            return CGFloat(rng.next(in: 0.45...0.95))
        case .medium:
            return CGFloat(rng.next(in: 0.28...0.65))
        case .large:
            return CGFloat(rng.next(in: 0.12...0.32))
        case .ultra:
            return CGFloat(rng.next(in: 0.08...0.22))
        }
    }

    private static func randomRotationFactor(
        sizeTier: SizeTier,
        rng: inout HomeAmbientRandom
    ) -> CGFloat {
        switch sizeTier {
        case .small:
            if rng.nextInt(in: 0...1) == 0 {
                return CGFloat(rng.next(in: -0.18...0.08))
            }
            return CGFloat(rng.next(in: -0.08...0.18))
        case .medium:
            if rng.nextInt(in: 0...1) == 0 {
                return CGFloat(rng.next(in: -0.08...0.04))
            }
            return CGFloat(rng.next(in: -0.04...0.08))
        case .large:
            return CGFloat(rng.next(in: -0.018...0.018))
        case .ultra:
            return CGFloat(rng.next(in: -0.010...0.010))
        }
    }

    private static func rotationClamp(sizeTier: SizeTier) -> CGFloat {
        switch sizeTier {
        case .small:
            return 110
        case .medium:
            return 92
        case .large:
            return 44
        case .ultra:
            return 18
        }
    }
}

private enum HomeAmbientShapeAssetKind {
    case normal
    case featuredLarge
    case ultra
}

private struct HomeAmbientShapeAssetCatalog {
    let normalIndices: [Int]
    let featuredLargeIndices: [Int]
    let ultraIndices: [Int]

    var hasUltra: Bool {
        !ultraIndices.isEmpty
    }

    init(fileNames: [String]) {
        var normal: [Int] = []
        var featuredLarge: [Int] = []
        var ultra: [Int] = []

        for (index, fileName) in fileNames.enumerated() {
            switch fileName.lowercased() {
            case "shape10.png":
                ultra.append(index)
            case "shape9.png", "shape11.png":
                featuredLarge.append(index)
            default:
                normal.append(index)
            }
        }

        normalIndices = normal
        featuredLargeIndices = featuredLarge
        ultraIndices = ultra
    }
}

private struct HomeAmbientShapeAssetSelection {
    let index: Int
    let kind: HomeAmbientShapeAssetKind
}

private struct HomeAmbientShapeAssetPicker {
    private var normalAssetBag: HomeAmbientShapeAssetBag
    private var featuredLargeAssetBag: HomeAmbientShapeAssetBag
    private var ultraAssetBag: HomeAmbientShapeAssetBag
    private var previousAssetIndex: Int?
    private var usedUltra = false

    init(catalog: HomeAmbientShapeAssetCatalog) {
        normalAssetBag = HomeAmbientShapeAssetBag(indices: catalog.normalIndices)
        featuredLargeAssetBag = HomeAmbientShapeAssetBag(indices: catalog.featuredLargeIndices)
        ultraAssetBag = HomeAmbientShapeAssetBag(indices: catalog.ultraIndices)
    }

    mutating func next(
        forceUltra: Bool,
        rng: inout HomeAmbientRandom
    ) -> HomeAmbientShapeAssetSelection {
        let roll = rng.next(in: 0.0...1.0)
        let selection: HomeAmbientShapeAssetSelection

        if forceUltra, ultraAssetBag.hasAssets, !usedUltra {
            selection = HomeAmbientShapeAssetSelection(
                index: ultraAssetBag.next(avoiding: previousAssetIndex, rng: &rng),
                kind: .ultra
            )
            usedUltra = true
        } else if roll < 0.16, ultraAssetBag.hasAssets, !usedUltra {
            selection = HomeAmbientShapeAssetSelection(
                index: ultraAssetBag.next(avoiding: previousAssetIndex, rng: &rng),
                kind: .ultra
            )
            usedUltra = true
        } else if roll < 0.42, featuredLargeAssetBag.hasAssets {
            selection = HomeAmbientShapeAssetSelection(
                index: featuredLargeAssetBag.next(avoiding: previousAssetIndex, rng: &rng),
                kind: .featuredLarge
            )
        } else {
            selection = HomeAmbientShapeAssetSelection(
                index: normalAssetBag.next(avoiding: previousAssetIndex, rng: &rng),
                kind: .normal
            )
        }

        previousAssetIndex = selection.index
        return selection
    }
}

private struct HomeAmbientShapeAssetBag {
    private let assetIndices: [Int]
    private var bag: [Int] = []

    var hasAssets: Bool {
        !assetIndices.isEmpty
    }

    init(indices: [Int]) {
        assetIndices = indices
    }

    mutating func next(avoiding avoidedIndex: Int?, rng: inout HomeAmbientRandom) -> Int {
        guard !assetIndices.isEmpty else { return 0 }

        if bag.isEmpty {
            refill(avoiding: avoidedIndex, rng: &rng)
        }

        var nextIndex = bag.removeLast()
        if let avoidedIndex, nextIndex == avoidedIndex, !bag.isEmpty {
            let replacement = bag.removeLast()
            bag.append(nextIndex)
            nextIndex = replacement
        }

        return nextIndex
    }

    private mutating func refill(avoiding avoidedIndex: Int?, rng: inout HomeAmbientRandom) {
        bag = assetIndices
        guard bag.count > 1 else { return }

        for index in stride(from: bag.count - 1, through: 1, by: -1) {
            let swapIndex = rng.nextInt(in: 0...index)
            if index != swapIndex {
                bag.swapAt(index, swapIndex)
            }
        }

        if let avoidedIndex, bag.last == avoidedIndex {
            bag.swapAt(bag.count - 1, bag.count - 2)
        }
    }
}

private struct HomeAmbientRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xD1B5_4A32_9C7E_44F1 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double((1 << 53) - 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let low = range.lowerBound
        let high = range.upperBound
        guard high >= low else { return low }
        return low + Int(nextUInt64() % UInt64(high - low + 1))
    }
}

private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, lower), upper)
}
