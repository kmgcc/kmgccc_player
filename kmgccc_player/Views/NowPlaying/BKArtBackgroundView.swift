//
//  BKArtBackgroundView.swift
//  myPlayer2
//
//  Now Playing artistic background:
//  - bk1/bk2 cycling at 1fps
//  - 10~16 opaque random tinted shapes
//  - transition via 6fps luma mask
//

import AppKit
import Combine
import CoreImage
import QuartzCore
import SwiftUI

@MainActor
final class BKArtBackgroundController: ObservableObject {
    @Published private(set) var transitionID: Int = 0
    @Published private(set) var lyricsColorTrackID: UUID?
    @Published private(set) var primaryBackgroundColor: NSColor?
    @Published private(set) var currentSurfaceBackgroundColor: NSColor?
    @Published private(set) var currentSurfaceUsesDotBackground: Bool = false
    @Published private(set) var currentSurfaceVariantIndex: Int?
    @Published private(set) var isUltraDarkActive: Bool = false
    @Published private(set) var lyricsColorSampleRevision: Int = 0

    func triggerTransition() {
        transitionID &+= 1
    }

    func beginLyricsColorSampling(for trackID: UUID?) {
        lyricsColorTrackID = trackID
        primaryBackgroundColor = nil
        currentSurfaceBackgroundColor = nil
        currentSurfaceUsesDotBackground = false
        currentSurfaceVariantIndex = nil
        isUltraDarkActive = false
    }

    func setPrimaryBackgroundColor(_ color: NSColor?, for trackID: UUID?) {
        guard lyricsColorTrackID == trackID else { return }
        guard !Self.colorsAreVisuallyEqual(primaryBackgroundColor, color) else { return }
        primaryBackgroundColor = color
    }

    func setCurrentSurfaceBackgroundColor(_ color: NSColor?, for trackID: UUID?) {
        guard lyricsColorTrackID == trackID else { return }
        guard !Self.colorsAreVisuallyEqual(currentSurfaceBackgroundColor, color) else { return }
        currentSurfaceBackgroundColor = color
    }

    func setCurrentSurfaceDescriptor(
        usesDotBackground: Bool,
        variantIndex: Int?,
        for trackID: UUID?
    ) {
        guard lyricsColorTrackID == trackID else { return }
        guard currentSurfaceUsesDotBackground != usesDotBackground
            || currentSurfaceVariantIndex != variantIndex
        else { return }
        currentSurfaceUsesDotBackground = usesDotBackground
        currentSurfaceVariantIndex = variantIndex
    }

    func setUltraDarkActive(_ isActive: Bool, for trackID: UUID?) {
        guard lyricsColorTrackID == trackID else { return }
        guard isUltraDarkActive != isActive else { return }
        isUltraDarkActive = isActive
    }

    func markLyricsColorSampleReady(for trackID: UUID?) {
        guard lyricsColorTrackID == trackID else { return }
        lyricsColorSampleRevision &+= 1
    }

    private static func colorsAreVisuallyEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            guard
                let lhsRGB = lhs.usingColorSpace(.deviceRGB),
                let rhsRGB = rhs.usingColorSpace(.deviceRGB)
            else {
                return false
            }
            let epsilon: CGFloat = 0.001
            return abs(lhsRGB.redComponent - rhsRGB.redComponent) < epsilon
                && abs(lhsRGB.greenComponent - rhsRGB.greenComponent) < epsilon
                && abs(lhsRGB.blueComponent - rhsRGB.blueComponent) < epsilon
                && abs(lhsRGB.alphaComponent - rhsRGB.alphaComponent) < epsilon
        default:
            return false
        }
    }
}

struct BKArtBackgroundView: View {
    enum ResourceProfile: Equatable, Sendable {
        case standard
        case cassetteForeground
    }

    enum DotRenderStyle: Equatable, Sendable {
        case dotGrid
        case solidCircles
    }

    enum MotionProfile: Equatable, Sendable {
        case window
        case fullscreenBalanced

        func dotFrameInterval(for style: DotRenderStyle) -> TimeInterval {
            switch (self, style) {
            case (.fullscreenBalanced, .solidCircles):
                return 1.0 / 30.0
            default:
                return 1.0 / 15.0
            }
        }

        func usesHighRateDotClock(for style: DotRenderStyle) -> Bool {
            self == .fullscreenBalanced && style == .solidCircles
        }

        var allowsAutomaticBackgroundPhaseCycling: Bool {
            true
        }
    }

    @ObservedObject var controller: BKArtBackgroundController
    let trackID: UUID?
    let artworkData: Data?
    let isPlaying: Bool
    var avoidanceRect: CGRect? = nil
    var resourceProfile: ResourceProfile = .standard
    var dotRenderStyle: DotRenderStyle = .dotGrid
    var motionProfile: MotionProfile = .window
    var initialPalette: [NSColor]? = nil
    var holdPaletteWhenArtworkMissing: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var palette: [NSColor] = Self.fallbackPalette
    @State private var lastArtworkSignature: Int = 0
    @State private var cachedBasePalette: [NSColor] = []
    @State private var cachedRichPalette: [NSColor] = []
    @State private var paletteRefreshTask: Task<Void, Never>?
    @State private var paletteRefreshToken = UUID()
    @State private var currentAnalysis: ArtworkColorAnalysis? = nil

    var body: some View {
        BKArtBackgroundRepresentable(
            controller: controller,
            trackID: trackID,
            transitionID: controller.transitionID,
            seed: seedValue,
            palette: displayPalette,
            isDark: colorScheme == .dark,
            isPlaying: isPlaying,
            avoidanceRect: avoidanceRect,
            resourceProfile: resourceProfile,
            dotRenderStyle: dotRenderStyle,
            motionProfile: motionProfile,
            analysis: currentAnalysis
        )
        .allowsHitTesting(false)
        .onAppear {
            refreshPalette()
        }
        .onChange(of: trackID) { _, _ in
            refreshPalette()
        }
        .onChange(of: artworkSignature) { _, _ in
            refreshPalette()
        }
        .onDisappear {
            paletteRefreshTask?.cancel()
            paletteRefreshTask = nil
        }
    }

    private var seedValue: UInt64 {
        guard let id = trackID else { return 0xA17D_4C59_10F3_778D }
        return UInt64(bitPattern: Int64(id.uuidString.hashValue))
    }

    private var artworkSignature: Int {
        artworkData?.hashValue ?? 0
    }

    private var displayPalette: [NSColor] {
        let seeded = seededPalette
        if !seeded.isEmpty, lastArtworkSignature == 0, cachedBasePalette.isEmpty, cachedRichPalette.isEmpty {
            return seeded
        }
        return palette
    }

    private var seededPalette: [NSColor] {
        let converted = (initialPalette ?? []).map { $0.usingColorSpace(.deviceRGB) ?? $0 }
        return converted.isEmpty ? [] : converted
    }

    private func refreshPalette() {
        paletteRefreshTask?.cancel()

        guard let data = artworkData else {
            if holdPaletteWhenArtworkMissing {
                Log.debug(
                    "[BKArt/palette] holding previous palette while artwork data is pending",
                    category: .ui
                )
                return
            }
            controller.beginLyricsColorSampling(for: trackID)
            palette = Self.fallbackPalette
            controller.setPrimaryBackgroundColor(Self.fallbackPalette.first, for: trackID)
            controller.setCurrentSurfaceBackgroundColor(nil, for: trackID)
            controller.setCurrentSurfaceDescriptor(
                usesDotBackground: false,
                variantIndex: nil,
                for: trackID
            )
            controller.setUltraDarkActive(false, for: trackID)
            return
        }

        let currentSignature = artworkSignature
        let currentTrackID = trackID
        controller.beginLyricsColorSampling(for: currentTrackID)
        applySeededPrimaryColorIfNeeded(for: currentTrackID)

        if currentSignature == lastArtworkSignature, !cachedBasePalette.isEmpty || !cachedRichPalette.isEmpty
        {
            applyResolvedPalette(
                basePalette: cachedBasePalette,
                richPalette: cachedRichPalette,
                signature: currentSignature,
                trackID: currentTrackID
            )
            return
        }

        let token = UUID()
        paletteRefreshToken = token

        paletteRefreshTask = Task(priority: .userInitiated) {
            let extracted: (base: [NSColor], rich: [NSColor])
            let analysis: ArtworkColorAnalysis?

            if let currentTrackID,
                let snapshot = await ArtworkAssetStore.shared.snapshotMetadata(
                    trackID: currentTrackID,
                    artworkData: data
                )
            {
                extracted = (snapshot.palette, snapshot.richPalette)
                analysis = snapshot.analysis
            } else {
                let resolvedAnalysis = await Task.detached(priority: .userInitiated) {
                    ArtworkColorExtractor.analyze(from: data)
                }.value
                extracted = (
                    resolvedAnalysis?.topPalette ?? ArtworkColorExtractor.uiThemePalette(
                        from: data, maxColors: 4),
                    resolvedAnalysis?.richPalette ?? ArtworkColorExtractor.uiThemePaletteRich(
                        from: data, desiredCount: 8)
                )
                analysis = resolvedAnalysis
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard paletteRefreshToken == token else { return }
                applyResolvedPalette(
                    basePalette: extracted.base,
                    richPalette: extracted.rich,
                    analysis: analysis,
                    signature: currentSignature,
                    trackID: currentTrackID
                )
                paletteRefreshTask = nil
            }
        }
    }

    private func applySeededPrimaryColorIfNeeded(for trackID: UUID?) {
        guard !seededPalette.isEmpty else { return }
        let harmonized = BKColorEngine.make(
            extracted: seededPalette,
            fallback: Self.fallbackPalette,
            isDark: colorScheme == .dark
        )
        let primaryBackgroundColor = predictedInitialBackgroundColor(from: harmonized)
            ?? seededPalette.first
            ?? Self.fallbackPalette.first
        controller.setPrimaryBackgroundColor(primaryBackgroundColor, for: trackID)
        controller.setUltraDarkActive(colorScheme == .dark && isUltraDarkPalette(harmonized), for: trackID)
    }

    private func applyResolvedPalette(
        basePalette: [NSColor],
        richPalette: [NSColor],
        analysis: ArtworkColorAnalysis? = nil,
        signature: Int,
        trackID: UUID?
    ) {
        currentAnalysis = analysis
        cachedBasePalette = basePalette
        cachedRichPalette = richPalette
        lastArtworkSignature = signature

        let resolvedPalette = BKExtractedPalettePolicy.select(
            analysis: analysis,
            basePalette: basePalette,
            richPalette: richPalette,
            fallbackPalette: Self.fallbackPalette
        )
        controller.setCurrentSurfaceBackgroundColor(nil, for: trackID)
        palette = resolvedPalette
        let harmonized = BKColorEngine.make(
            extracted: resolvedPalette,
            fallback: Self.fallbackPalette,
            isDark: colorScheme == .dark,
            analysis: analysis
        )
        let primaryBackgroundColor = stableLyricsBackgroundColor(from: harmonized)
            ?? predictedInitialBackgroundColor(from: harmonized)
            ?? resolvedPalette.first
            ?? Self.fallbackPalette.first
        controller.setPrimaryBackgroundColor(primaryBackgroundColor, for: trackID)
        controller.setUltraDarkActive(
            colorScheme == .dark && isUltraDarkPalette(harmonized, analysis: analysis),
            for: trackID
        )
        controller.markLyricsColorSampleReady(for: trackID)
        Self.logExtracted(resolvedPalette, analysis: analysis)
    }

    private static func logExtracted(_ palette: [NSColor], analysis: ArtworkColorAnalysis?) {
        guard LogConfig.isCategoryEnabled(.ui) else { return }
        let hexes = palette.prefix(8).compactMap { color -> String? in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
            return String(
                format: "#%02X%02X%02X",
                UInt8(min(max(rgb.redComponent, 0), 1) * 255),
                UInt8(min(max(rgb.greenComponent, 0), 1) * 255),
                UInt8(min(max(rgb.blueComponent, 0), 1) * 255)
            )
        }.joined(separator: " ")
        let salientHashes: Set<String> = {
            guard let salients = analysis?.salientHighlightPalette else { return [] }
            return Set(salients.compactMap { color -> String? in
                guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
                return String(
                    format: "#%02X%02X%02X",
                    UInt8(min(max(rgb.redComponent, 0), 1) * 255),
                    UInt8(min(max(rgb.greenComponent, 0), 1) * 255),
                    UInt8(min(max(rgb.blueComponent, 0), 1) * 255)
                )
            })
        }()
        let hasSalient = palette.contains { color in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
            let hex = String(
                format: "#%02X%02X%02X",
                UInt8(min(max(rgb.redComponent, 0), 1) * 255),
                UInt8(min(max(rgb.greenComponent, 0), 1) * 255),
                UInt8(min(max(rgb.blueComponent, 0), 1) * 255)
            )
            return salientHashes.contains(hex)
        }
        Log.debug(
            "[BKArt/palette] ultraDark=\(analysis?.isUltraDark ?? false) nearMono=\(analysis?.isNearMonochrome ?? false) hasSalient=\(hasSalient) colors=[\(hexes)]",
            category: .ui
        )
    }

    private func predictedInitialBackgroundColor(from harmonized: HarmonizedPalette) -> NSColor? {
        let variantCount = max(1, harmonized.bgVariants.isEmpty ? 1 : harmonized.bgVariants.count)
        let variantIndex = Int((seedValue ^ 0x7A6C_2E43_5B91_F0D3) % UInt64(variantCount))
        let toneVariant = !harmonized.bgVariants.isEmpty
            ? harmonized.bgVariants[min(max(0, variantIndex), harmonized.bgVariants.count - 1)]
            : harmonized.bgStops
        return toneVariant.first.flatMap { NSColor(cgColor: $0) }
    }

    private func stableLyricsBackgroundColor(from harmonized: HarmonizedPalette) -> NSColor? {
        if controller.currentSurfaceUsesDotBackground {
            return harmonized.bgStops.first.flatMap { NSColor(cgColor: $0) }
        }

        if let variantIndex = controller.currentSurfaceVariantIndex {
            let toneVariant = !harmonized.bgVariants.isEmpty
                ? harmonized.bgVariants[min(max(0, variantIndex), harmonized.bgVariants.count - 1)]
                : harmonized.bgStops
            return toneVariant.first.flatMap { NSColor(cgColor: $0) }
        }

        return nil
    }

    private func isUltraDarkPalette(
        _ harmonized: HarmonizedPalette,
        analysis: ArtworkColorAnalysis? = nil
    ) -> Bool {
        // Prefer the orthogonal analysis flag. It separates the lightness
        // regime from the chromatic regime, which means deep-but-coloured
        // covers (deep navy, dark crimson, midnight teal) trigger the same
        // darkness-preserving UltraDark protection path as truly grayscale
        // covers, while still letting the engine expose their hue through the
        // multi-colour shape tier.
        if let analysis, analysis.isUltraDark {
            return true
        }
        let luma = harmonized.imageCoverLuma
        return (luma < 0.36 && harmonized.areaDominantB < 0.30)
            || (luma < 0.30 && harmonized.grayScore > 0.70)
    }

    fileprivate static var fallbackPalette: [NSColor] {
        BKExtractedPalettePolicy.fallbackPalette
    }
}

private struct BKArtBackgroundRepresentable: NSViewRepresentable {
    let controller: BKArtBackgroundController
    let trackID: UUID?
    let transitionID: Int
    let seed: UInt64
    let palette: [NSColor]
    let isDark: Bool
    let isPlaying: Bool
    let avoidanceRect: CGRect?
    let resourceProfile: BKArtBackgroundView.ResourceProfile
    let dotRenderStyle: BKArtBackgroundView.DotRenderStyle
    let motionProfile: BKArtBackgroundView.MotionProfile
    let analysis: ArtworkColorAnalysis?

    func makeNSView(context: Context) -> BKArtBackgroundLayerView {
        FSDiagnostics.emit("BKArtBackground.makeNSView BEGIN t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .ui)
        let contentView = BKArtBackgroundLayerView()
        contentView.backgroundController = controller
        contentView.trackID = trackID
        contentView.updatePalette(palette, isDark: isDark, analysis: analysis)
        contentView.updateAvoidanceRect(avoidanceRect)
        contentView.updateResourceProfile(resourceProfile)
        contentView.updateDotRenderStyle(dotRenderStyle)
        contentView.updateMotionProfile(motionProfile)
        contentView.ensureBaseContainer(seed: seed)
        contentView.setPlayback(isPlaying: isPlaying)
        contentView.currentTransitionID = transitionID
        return contentView
    }

    func updateNSView(_ nsView: BKArtBackgroundLayerView, context: Context) {
        FSDiagnostics.emit("BKArtBackground.updateNSView BEGIN t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .ui)
        nsView.backgroundController = controller
        nsView.trackID = trackID
        nsView.updatePalette(palette, isDark: isDark, analysis: analysis)
        nsView.updateAvoidanceRect(avoidanceRect)
        nsView.updateResourceProfile(resourceProfile)
        nsView.updateDotRenderStyle(dotRenderStyle)
        nsView.updateMotionProfile(motionProfile)
        nsView.ensureBaseContainer(seed: seed)
        nsView.setPlayback(isPlaying: isPlaying)

        if nsView.currentTransitionID != transitionID {
            nsView.currentTransitionID = transitionID
            nsView.triggerTransition(seed: seed &+ UInt64(truncatingIfNeeded: transitionID))
        }
    }

    static func dismantleNSView(_ nsView: BKArtBackgroundLayerView, coordinator: ()) {
        nsView.prepareForDismissal()
    }
}

@MainActor
private final class BKArtBackgroundLayerView: NSView {
    #if DEBUG
        private static var liveInstanceCount = 0
        private static let lifecycleLoggingEnabled =
            ProcessInfo.processInfo.environment["KMGCCC_DEBUG_NOWPLAYING_LIFECYCLE"] == "1"
    #endif

    weak var backgroundController: BKArtBackgroundController?
    var trackID: UUID?

    private final class CGImageBox: @unchecked Sendable {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    private final class CGImageArrayBox: @unchecked Sendable {
        let images: [CGImage]

        init(images: [CGImage]) {
            self.images = images
        }
    }

    private final class AssetLoadSnapshotBox: @unchecked Sendable {
        nonisolated let budget: BKThemeAssets.PixelBudget
        nonisolated let backgroundImages: [CGImage]
        nonisolated let backgroundSourceIndices: [Int]
        nonisolated let shapes: BKThemeAssets.ShapeLoadResult
        nonisolated let maskFrames: [CGImage]
        nonisolated let fullscreenCircleImages: BKThemeAssets.FullscreenCircleLoadResult

        nonisolated init(
            budget: BKThemeAssets.PixelBudget,
            backgroundImages: [CGImage],
            backgroundSourceIndices: [Int],
            shapes: BKThemeAssets.ShapeLoadResult,
            maskFrames: [CGImage],
            fullscreenCircleImages: BKThemeAssets.FullscreenCircleLoadResult
        ) {
            self.budget = budget
            self.backgroundImages = backgroundImages
            self.backgroundSourceIndices = backgroundSourceIndices
            self.shapes = shapes
            self.maskFrames = maskFrames
            self.fullscreenCircleImages = fullscreenCircleImages
        }
    }

    private struct ToneStopComponent: Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        nonisolated init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        nonisolated init(color: NSColor) {
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
            red = r
            green = g
            blue = b
            alpha = a
        }
    }

    private enum BackgroundAssetMode {
        case currentPhaseLowRes
        case fullSet
    }

    private struct ShapeState {
        var basePosition: CGPoint
        var driftX: CGFloat
        var driftY: CGFloat
        var phase: CGFloat
        var phaseSpeed: CGFloat
        var angle: CGFloat
        var angularSpeed: CGFloat
    }

    private struct SelectedShape {
        var image: CGImage
        var scaleMultiplier: CGFloat
        var isEdgePinned: Bool
    }

    private enum BackgroundStyle: Int {
        case image = 0
        case dot = 1
    }

    fileprivate enum TransitionRequestResult: Equatable {
        case started
        case deferred
        case ignored
    }

    private enum DotMotionState {
        case idle(TimeInterval)
        case moving(Double)
    }

    private enum FullscreenCircleLayerRole {
        case outer
        case inner
    }

    private struct DotAnimState {
        var motion: DotMotionState
        var start: CGPoint
        var cp1: CGPoint
        var cp2: CGPoint
        var end: CGPoint
        var duration: TimeInterval
        // Overlap logic
        var leadInOverlapT: Double  // e.g. 0.85, at which point next slot starts
    }

    private class DotSlot {
        let rootLayer: CALayer = CALayer()
        var maskBig: CALayer?
        var maskSmall: CALayer?
        var cellBig: CAShapeLayer?  // Reference to replicator prototype or similar if we want to change color
        var cellSmall: CAShapeLayer?
        var circleOuterImageLayer: CALayer?
        var circleInnerImageLayer: CALayer?
        var circleOuterImageSource: CGImage?
        var circleInnerImageSource: CGImage?

        var anim: DotAnimState
        var color: CGColor?
        let colorSeed: UInt64
        var outerRotationBaseAngle: CGFloat
        var outerRotationTravelAngle: CGFloat
        var innerRotationBaseAngle: CGFloat
        var innerRotationTravelAngle: CGFloat

        var baseRadius: CGFloat
        var radiusBig: CGFloat
        var radiusSmall: CGFloat
        var maskBaseRadiusBig: CGFloat
        var maskBaseRadiusSmall: CGFloat

        init(anim: DotAnimState, baseRadius: CGFloat, colorSeed: UInt64) {
            self.anim = anim
            self.colorSeed = colorSeed == 0 ? 0xA17D_4C59_10F3_778D : colorSeed
            self.baseRadius = baseRadius
            self.radiusBig = 0
            self.radiusSmall = 0
            self.maskBaseRadiusBig = max(1, baseRadius * 0.75)
            self.maskBaseRadiusSmall = max(1, baseRadius)
            self.outerRotationBaseAngle = 0
            self.outerRotationTravelAngle = 0
            self.innerRotationBaseAngle = 0
            self.innerRotationTravelAngle = 0
        }
    }

    private final class Container {
        let layer = CALayer()
        let backgroundLayer = CALayer()
        let backgroundToneLayer = CALayer()
        var ultraDarkOverlay: CALayer?
        let shapesRoot = CALayer()

        var style: BackgroundStyle = .image
        var dotRoot: CALayer?
        var dotGradient: CAGradientLayer?

        // Multi-slot support for overlapping dot windows
        var dotSlots: [DotSlot] = []

        // Removed old single-instance properties
        // var dotMasks... var dotAnim... var dotCells... var dotColor...

        var shapeLayers: [CALayer] = []
        var shapeStates: [ShapeState] = []
        var shapeTints: [CGColor] = []
        var shapeSwatches: [CGColor] = []
        var swatchDiagnostics: BKColorEngine.ShapeSwatchDiagnostics?
        var bgVariantIndex: Int = 0
        var seed: UInt64 = 0

        init(frame: CGRect) {
            layer.frame = frame
            layer.masksToBounds = true
            layer.backgroundColor = NSColor.black.cgColor
            layer.isOpaque = true

            backgroundLayer.frame = frame
            backgroundLayer.backgroundColor = NSColor.black.cgColor
            backgroundLayer.contentsGravity = .resizeAspectFill
            backgroundLayer.isOpaque = true
            backgroundLayer.contentsFormat = .RGBA8Uint
            layer.addSublayer(backgroundLayer)

            backgroundToneLayer.frame = frame
            layer.addSublayer(backgroundToneLayer)

            shapesRoot.frame = frame
            layer.addSublayer(shapesRoot)
        }
    }

    var currentTransitionID: Int = 0

    private let assets = BKThemeAssets.shared
    private var harmonized: HarmonizedPalette = BKColorEngine.make(
        extracted: BKArtBackgroundView.fallbackPalette,
        fallback: BKArtBackgroundView.fallbackPalette,
        isDark: false
    )
    private var currentAnalysis: ArtworkColorAnalysis? = nil
    private var extractedPaletteForSwatches: [NSColor] = BKArtBackgroundView.fallbackPalette
    private var paletteSignature: String = ""
    private var loadedBackgrounds: [CGImage] = []
    private var loadedShapes = BKThemeAssets.ShapeLoadResult(
        images: [],
        scaleByIndex: [:],
        edgePinnedIndices: []
    )
    private var loadedFullscreenCircleImages = BKThemeAssets.FullscreenCircleLoadResult()
    private var loadedFullscreenCircleMaxPixel = 0
    private var loadedMaskFrames: [CGImage] = []
    private var loadedBudget = BKThemeAssets.PixelBudget(background: 0, shape: 0, mask: 0)
    private var loadedBackgroundSourceIndices: [Int] = []
    private let tintedBackgroundCache = NSCache<NSString, CGImageBox>()
    private var fromContainer: Container?
    private var toContainer: Container?
    private var transitionMaskLayer: CALayer?

    private var backgroundPhase: Int = 0
    private var backgroundPhaseFloat: Double = 0
    private var maskFrameIndex: Int = 0
    private var maskFrameProgress: Double = 0
    private var lastLayoutSize: CGSize = .zero
    private var rebuildSeed: UInt64 = 0
    private let animationClock = BackgroundAnimationClock.shared
    private var clockLeaseID: UUID?

    private var backgroundClockSubscription: AnyCancellable?
    private var shapeClockSubscription: AnyCancellable?
    private var dotClockSubscription: AnyCancellable?
    private var transitionClockSubscription: AnyCancellable?
    private var autoTransitionTimer: DispatchSourceTimer?
    private var speedRampClockSubscription: AnyCancellable?
    private var maskWarmupTask: Task<Void, Never>?
    private var assetSnapshotTask: Task<Void, Never>?
    private var assetSnapshotGeneration: UInt64 = 0
    private var initialResourceUpgradeTask: Task<Void, Never>?
    private var backgroundRenderTasks: [String: Task<Void, Never>] = [:]
    private var backgroundRenderGeneration: UInt64 = 0
    private var pendingTransitionSeed: UInt64?
    private var transitionSeedCounter: UInt64 = 0
    private var speedCurrent: Double = 1.0
    private var speedTarget: Double = 1.0
    private var lastTickTime: CFTimeInterval = CACurrentMediaTime()
    private var isPausedFrozen = false
    private var pendingBoundsRebuild = false
    private var isTransitionInFlight = false
    private var rebuildDebounceTask: Task<Void, Never>?
    private let ultraDarkOverlayOpacity: Float = 0.24
    private var activeAvoidanceRect: CGRect?
    private var backgroundAssetMode: BackgroundAssetMode = .currentPhaseLowRes
    private var resourceProfile: BKArtBackgroundView.ResourceProfile = .standard
    private var dotRenderStyle: BKArtBackgroundView.DotRenderStyle = .dotGrid
    private var motionProfile: BKArtBackgroundView.MotionProfile = .window

    private static let fullscreenDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["KMGCCC_FULLSCREEN_BK_DIAGNOSTICS"] == "1"
    private nonisolated static let circleTintContext = CIContext(options: [.cacheIntermediates: false])

    // Style Selector State
    private var lastStyle: BackgroundStyle?
    private var lastStyleRunCount: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ensureRootLayerIfNeeded()
        tintedBackgroundCache.countLimit = 6
        tintedBackgroundCache.totalCostLimit = 48 * 1024 * 1024
        logLifecycle("init")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            logLifecycle("deinit")
            releaseHeavyResources()
            backgroundClockSubscription?.cancel()
            shapeClockSubscription?.cancel()
            dotClockSubscription?.cancel()
            transitionClockSubscription?.cancel()
            autoTransitionTimer?.cancel()
            speedRampClockSubscription?.cancel()
            if let clockLeaseID {
                animationClock.release(clockLeaseID)
                self.clockLeaseID = nil
            }
            maskWarmupTask?.cancel()
            assetSnapshotTask?.cancel()
            initialResourceUpgradeTask?.cancel()
            rebuildDebounceTask?.cancel()
            backgroundRenderTasks.values.forEach { $0.cancel() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimers()
            releaseHeavyResources()
        } else {
            startTimersIfNeeded()
        }
    }

    func prepareForDismissal() {
        FSDiagnostics.emit("BKArtBackground.prepareForDismissal BEGIN t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .ui)
        stopTimers()
        releaseHeavyResources()
        activeAvoidanceRect = nil
        backgroundController = nil
        trackID = nil
        tearDownRootLayer()
        FSDiagnostics.emit("BKArtBackground.prepareForDismissal END t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .ui)
    }

    func updateResourceProfile(_ profile: BKArtBackgroundView.ResourceProfile) {
        guard resourceProfile != profile else { return }
        resourceProfile = profile
        cancelInitialResourceUpgradeTask()
        syncLoadedAssetsIfNeeded()
        applyCurrentBackgroundPhase()
        scheduleInitialResourceUpgradeIfNeeded()
    }

    func updateDotRenderStyle(_ style: BKArtBackgroundView.DotRenderStyle) {
        guard dotRenderStyle != style else { return }
        let wasRunning = isDotAnimationDriverRunning
        stopDotAnimationDriver()
        dotRenderStyle = style
        logDiagnostics("dotRenderStyle=\(style)")
        if wasRunning {
            startDotTimerIfNeeded()
        }
    }

    func updateMotionProfile(_ profile: BKArtBackgroundView.MotionProfile) {
        guard motionProfile != profile else { return }
        let wasDotRunning = isDotAnimationDriverRunning
        let wasBackgroundRunning = backgroundClockSubscription != nil
        stopDotAnimationDriver()
        if wasBackgroundRunning {
            backgroundClockSubscription?.cancel()
            backgroundClockSubscription = nil
        }
        motionProfile = profile
        logDiagnostics("motionProfile=\(profile)")
        if wasBackgroundRunning {
            startBackgroundTimerIfNeeded()
        }
        if wasDotRunning {
            startDotTimerIfNeeded()
        }
        updateClockActivity()
    }

    private static let resizeRebuildThreshold: CGFloat = 48

    override func layout() {
        super.layout()
        guard !bounds.isEmpty else { return }
        ensureRootLayerIfNeeded()
        layer?.frame = bounds

        if fromContainer == nil {
            ensureBaseContainer(seed: rebuildSeed)
        }

        let isInitialLayout = lastLayoutSize == .zero
        let deltaW = abs(lastLayoutSize.width - bounds.width)
        let deltaH = abs(lastLayoutSize.height - bounds.height)
        lastLayoutSize = bounds.size

        if !isInitialLayout && (deltaW > Self.resizeRebuildThreshold || deltaH > Self.resizeRebuildThreshold) {
            if isTransitionInFlight || toContainer != nil {
                pendingBoundsRebuild = true
                layoutContainer(fromContainer)
                layoutContainer(toContainer)
                transitionMaskLayer?.frame = expandedBounds
                return
            }
            // During live resize, layout existing container and debounce the rebuild
            // to avoid repeated random-layout rebuilds causing flicker.
            layoutContainer(fromContainer)
            transitionMaskLayer?.frame = expandedBounds
            scheduleBoundsRebuildDebounce()
            return
        }

        layoutContainer(fromContainer)
        layoutContainer(toContainer)
        transitionMaskLayer?.frame = expandedBounds
    }

    private func scheduleBoundsRebuildDebounce() {
        rebuildDebounceTask?.cancel()
        rebuildDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            guard let self, !Task.isCancelled else { return }
            self.rebuildForCurrentBounds()
        }
    }

    func updatePalette(_ colors: [NSColor], isDark: Bool, analysis: ArtworkColorAnalysis? = nil) {
        guard !colors.isEmpty else { return }
        let converted = colors.map { $0.usingColorSpace(.deviceRGB) ?? $0 }
        applyPalette(converted, isDark: isDark, analysis: analysis)
    }

    func updateAvoidanceRect(_ rect: CGRect?) {
        let normalized = rect?.standardized
        guard activeAvoidanceRect != normalized else { return }
        activeAvoidanceRect = normalized

        guard !bounds.isEmpty else { return }
        rebuildForCurrentBounds()
    }

    func setPlayback(isPlaying: Bool) {
        let newTarget = isPlaying ? 1.0 : 0.0
        guard newTarget != speedTarget || (isPlaying && isPausedFrozen) else { return }

        speedTarget = newTarget
        lastTickTime = CACurrentMediaTime()

        if isPlaying {
            if isPausedFrozen {
                resumeAnimationTimersAfterFreeze()
            }
            if autoTransitionTimer == nil
                && !isTransitionInFlight
                && toContainer == nil
                && pendingTransitionSeed == nil {
                scheduleNextAutoTransition()
            }
        } else {
            autoTransitionTimer?.cancel()
            autoTransitionTimer = nil
        }

        startSpeedRampTimerIfNeeded()
    }

    private func applyPalette(_ converted: [NSColor], isDark: Bool, analysis: ArtworkColorAnalysis? = nil) {
        extractedPaletteForSwatches = converted
        currentAnalysis = analysis
        let colorSignature = Self.paletteSignature(for: converted.map(\.cgColor))
        let nearFlag = analysis?.isNearMonochrome == true ? 1 : 0
        let trustedFlag = analysis?.hasTrustedHueCandidate == true ? 1 : 0
        let ultraFlag = analysis?.isUltraDark == true ? 1 : 0
        let displaySignature = analysis.map {
            Self.paletteSignature(for: $0.displayPalette.map(\.cgColor))
        } ?? "nil"
        let analysisSignature =
            "near:\(nearFlag)|trusted:\(trustedFlag)|ultra:\(ultraFlag)|display:\(displaySignature)"
        let signature = "\(colorSignature)|dark:\(isDark ? 1 : 0)|\(analysisSignature)"
        guard signature != paletteSignature else { return }

        harmonized = BKColorEngine.make(
            extracted: converted,
            fallback: BKArtBackgroundView.fallbackPalette,
            isDark: isDark,
            analysis: analysis
        )
        paletteSignature = signature
        cancelBackgroundRenderTasks()
        tintedBackgroundCache.removeAllObjects()
        let toneColorForVariant: (Int) -> CGColor = { index in
            let stops = !self.harmonized.bgVariants.isEmpty
                ? self.harmonized.bgVariants[min(max(0, index), self.harmonized.bgVariants.count - 1)]
                : self.harmonized.bgStops
            return stops.first ?? (self.harmonized.isDark ? NSColor.black.cgColor : NSColor.white.cgColor)
        }
        let toneOpacity: Float
        if harmonized.isDark {
            toneOpacity = 0.30
        } else {
            toneOpacity = 0.18
        }

        func applyTone(_ container: Container?) {
            guard let container else { return }
            container.backgroundToneLayer.backgroundColor = toneColorForVariant(container.bgVariantIndex)
            container.backgroundToneLayer.opacity = toneOpacity
            container.backgroundToneLayer.compositingFilter = nil
            updateUltraDarkOverlay(for: container)
        }

        applyTone(fromContainer)
        applyTone(toContainer)
        retintDotSlots(in: fromContainer)
        retintDotSlots(in: toContainer)
        prewarmTintedBackgroundsIfNeeded()
        applyCurrentBackgroundPhase()
        publishCurrentSurfaceBackgroundColor()

        if let from = fromContainer { updateDotGradient(from) }
        if let to = toContainer { updateDotGradient(to) }

        retintShapes(in: fromContainer)
        retintShapes(in: toContainer)
    }

    func ensureBaseContainer(seed: UInt64) {
        FSDiagnostics.emit("BKArtBackground.ensureBaseContainer BEGIN t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .ui)
        rebuildSeed = seed
        guard fromContainer == nil, !bounds.isEmpty else { return }
        ensureRootLayerIfNeeded()
        syncLoadedAssetsIfNeeded()
        let container = buildContainer(seed: seed)
        fromContainer = container
        commitStyleHistory(container.style)
        layer?.addSublayer(container.layer)
        applyCurrentBackgroundPhase()
        publishCurrentSurfaceBackgroundColor()
        startTimersIfNeeded()
        scheduleInitialResourceUpgradeIfNeeded()
        FSDiagnostics.emit("BKArtBackground.ensureBaseContainer END t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .ui)
    }

    @discardableResult
    func triggerTransition(seed: UInt64) -> TransitionRequestResult {
        guard !bounds.isEmpty else { return .ignored }
        guard speedTarget > 0.01 else {
            pendingTransitionSeed = seed
            return .deferred
        }
        rebuildSeed = seed
        ensureBaseContainer(seed: seed)
        guard let current = fromContainer else { return .ignored }
        guard toContainer == nil, !isTransitionInFlight else {
            pendingTransitionSeed = seed
            return .deferred
        }
        guard transitionAssetsReadyForCurrentTarget() else {
            pendingTransitionSeed = seed
            startTransitionAssetWarmupIfNeeded()
            return .deferred
        }
        let maskFrames = resolvedMaskFrames()
        guard !maskFrames.isEmpty else {
            pendingTransitionSeed = seed
            startTransitionAssetWarmupIfNeeded()
            return .deferred
        }
        pendingTransitionSeed = nil

        enterTransitionPerformanceMode()
        stopTransitionTimer()
        // Mix seed more aggressively
        let mixed = seed ^ 0x9E37_79B9_7F4A_7C15 ^ (UInt64(maskFrameIndex) &* 0xBF58_476D_1CE4_E5B9)
        let next = buildContainer(seed: mixed)
        toContainer = next
        layer?.insertSublayer(next.layer, above: current.layer)
        applyBackgroundPhase(to: next, allowSynchronousRender: false)

        let mask = CALayer()
        mask.frame = expandedBounds
        mask.contentsGravity = .resize
        mask.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        mask.contents = maskFrames[0]
        next.layer.mask = mask
        transitionMaskLayer = mask
        maskFrameIndex = 0
        maskFrameProgress = 0
        startTransitionTimer()
        return .started
    }

    private func rebuildForCurrentBounds() {
        guard !bounds.isEmpty else { return }
        guard fromContainer != nil, window != nil else {
            rebuildImmediatelyForCurrentBounds()
            return
        }
        guard !isTransitionInFlight, toContainer == nil else {
            pendingBoundsRebuild = true
            return
        }
        guard speedTarget > 0.01 else {
            pendingBoundsRebuild = true
            return
        }

        let result = triggerTransition(seed: nextTransitionSeed())
        guard result == .ignored else { return }

        // No visible transition can be started only if the current state is not
        // usable. Fall back to an immediate rebuild rather than leaving a dead layer.
        rebuildImmediatelyForCurrentBounds()
    }

    private func rebuildImmediatelyForCurrentBounds() {
        guard !bounds.isEmpty else { return }
        pendingBoundsRebuild = false
        stopTransitionTimer()
        transitionMaskLayer?.contents = nil
        transitionMaskLayer?.removeFromSuperlayer()
        let replacement = buildContainer(seed: rebuildSeed)
        fromContainer?.layer.removeFromSuperlayer()
        toContainer?.layer.removeFromSuperlayer()
        transitionMaskLayer = nil
        fromContainer = replacement
        toContainer = nil
        commitStyleHistory(replacement.style)

        layer?.addSublayer(replacement.layer)
        applyCurrentBackgroundPhase()
        publishCurrentSurfaceBackgroundColor()
        startTimersIfNeeded()
        scheduleInitialResourceUpgradeIfNeeded()
    }

    private func layoutContainer(_ container: Container?) {
        guard let container else { return }
        let layoutFrame = expandedBounds
        container.layer.frame = layoutFrame
        container.backgroundLayer.frame = layoutFrame
        container.backgroundLayer.contentsScale =
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        container.backgroundToneLayer.frame = layoutFrame
        container.ultraDarkOverlay?.frame = layoutFrame
        container.ultraDarkOverlay?.contentsScale =
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        container.shapesRoot.frame = layoutFrame

        if let dotRoot = container.dotRoot {
            dotRoot.frame = layoutFrame
            container.dotGradient?.frame = dotRoot.bounds

            for slot in container.dotSlots {
                slot.rootLayer.frame = dotRoot.bounds
                if dotRenderStyle == .dotGrid {
                    // Dot grid layers fill the root; their masks are the moving local circles.
                    slot.rootLayer.sublayers?.forEach { sublayer in
                        sublayer.frame = dotRoot.bounds
                    }
                }
            }
        }
    }

    private func buildContainer(seed: UInt64) -> Container {
        syncLoadedAssetsIfNeeded()
        let container = Container(frame: bounds)
        let normalizedSeed = seed == 0 ? 0xA17D_4C59_10F3_778D : seed
        container.seed = normalizedSeed
        var rng = BKSeededRandom(seed: normalizedSeed)
        let hasImageBackgrounds = !loadedBackgrounds.isEmpty

        // 1) 50/50 choose + anti-streak breaker.
        let bit = ((normalizedSeed >> 17) ^ (normalizedSeed >> 41) ^ normalizedSeed) & 1
        var proposedStyle: BackgroundStyle = (bit == 0) ? .image : .dot
        if fromContainer == nil, hasImageBackgrounds {
            // Ensure first screen shows artwork background at least once.
            proposedStyle = .image
        }
        if !hasImageBackgrounds {
            proposedStyle = .dot
        } else if let last = lastStyle, lastStyleRunCount >= 1, proposedStyle == last {
            proposedStyle = (last == .dot) ? .image : .dot
        }
        container.style = proposedStyle
        let variantCount = max(1, backgroundToneVariants().count)
        container.bgVariantIndex = Int((normalizedSeed ^ 0x7A6C_2E43_5B91_F0D3) % UInt64(variantCount))
        logDiagnostics(
            "buildContainer style=\(container.style) seed=\(String(normalizedSeed, radix: 16)) dotRenderStyle=\(dotRenderStyle) profile=\(resourceProfile) budget=\(debugBudgetDescription(currentAssetBudget())) fullBudget=\(debugBudgetDescription(fullResolutionAssetBudget())) trackID=\(trackID?.uuidString ?? "nil")"
        )

        container.backgroundToneLayer.frame = expandedBounds
        let isDark = harmonized.isDark
        let toneVariant = !harmonized.bgVariants.isEmpty
            ? harmonized.bgVariants[min(container.bgVariantIndex, harmonized.bgVariants.count - 1)]
            : harmonized.bgStops
        container.backgroundToneLayer.backgroundColor =
            toneVariant.first ?? (isDark ? NSColor.black.cgColor : NSColor.white.cgColor)
        let toneOpacity: Float
        if isDark {
            toneOpacity = 0.30
        } else {
            toneOpacity = 0.18
        }
        container.backgroundToneLayer.opacity = toneOpacity
        container.backgroundToneLayer.compositingFilter = nil

        applyStyle(to: container, style: container.style, rng: &rng)
        let swatchResult = BKColorEngine.makeShapeSwatches(
            seed: normalizedSeed ^ 0xA54F_66D1_9E37_79B9,
            extracted: extractedPaletteForSwatches,
            fallback: BKArtBackgroundView.fallbackPalette,
            isDark: harmonized.isDark,
            analysis: currentAnalysis
        )
        container.shapeSwatches = swatchResult.colors.isEmpty ? harmonized.shapePool : swatchResult.colors
        container.swatchDiagnostics = swatchResult.diagnostics

        let count = targetShapeCount(using: &rng)
        let chosenShapes = chooseShapeImages(count: count, rng: &rng)
        let plannedTints = makeShapeTintPlan(
            count: chosenShapes.count,
            swatches: container.shapeSwatches,
            rng: &rng
        )
        container.shapeTints = plannedTints

        let shapeAvoidanceRect = activeAvoidanceRect?.insetBy(dx: -18, dy: -22)

        for (shapeIndex, selectedShape) in chosenShapes.enumerated() {
            let base = min(bounds.width, bounds.height)
            let randomScale = CGFloat(rng.next(in: 0.50...1.80))
            let baseSide = base * randomScale * 0.22

            let minSpecialRandomScale: CGFloat = selectedShape.scaleMultiplier >= 3.0 ? 1.20
                : (selectedShape.scaleMultiplier >= 2.0 ? 0.95 : 0.50)
            let enforcedBaseSide = base * max(randomScale, minSpecialRandomScale) * 0.22
            let side = selectedShape.scaleMultiplier > 1.0
                ? (enforcedBaseSide * selectedShape.scaleMultiplier)
                : baseSide
            let point = selectedShape.isEdgePinned
                ? randomPinnedEdgePoint(side: side, rng: &rng)
                : randomEdgePoint(side: side, centerAvoidanceRect: shapeAvoidanceRect, rng: &rng)

            let size = CGSize(width: side, height: side)
            let finalTint = plannedTints[shapeIndex]
            let shape = makeTintedShapeLayer(image: selectedShape.image, size: size, tint: finalTint)
            shape.opacity = 1.0
            shape.position = point

            container.shapesRoot.addSublayer(shape)
            container.shapeLayers.append(shape)

            let state = makeShapeState(
                basePosition: point,
                isEdgePinned: selectedShape.isEdgePinned,
                centerAvoidanceRect: shapeAvoidanceRect,
                rng: &rng
            )
            container.shapeStates.append(state)
        }

        ensureLayerOrder(for: container)
        updateUltraDarkOverlay(for: container)

#if DEBUG
        let minExpectedShapeCount = loadedShapes.images.isEmpty ? 0 : 10
        assert(container.shapeLayers.count >= minExpectedShapeCount)
        assert(container.shapesRoot.sublayers?.count ?? 0 >= minExpectedShapeCount)
#endif

        return container
    }

    private func commitStyleHistory(_ style: BackgroundStyle) {
        if lastStyle == style {
            lastStyleRunCount += 1
        } else {
            lastStyle = style
            lastStyleRunCount = 0
        }
    }

    private func applyStyle(
        to container: Container,
        style: BackgroundStyle,
        rng: inout BKSeededRandom
    ) {
        container.style = style

        switch style {
        case .image:
            if let dotRoot = container.dotRoot {
                dotRoot.removeFromSuperlayer()
            }
            container.dotSlots.forEach { $0.rootLayer.removeFromSuperlayer() }
            container.dotSlots.removeAll(keepingCapacity: false)
            container.dotGradient = nil
            container.dotRoot = nil
            container.backgroundToneLayer.isHidden = false

#if DEBUG
            assert(container.dotRoot == nil || container.dotRoot?.isHidden == true)
#endif

        case .dot:
            if container.dotRoot == nil {
                setupDotBackground(in: container, rng: &rng)
            }
            container.backgroundToneLayer.isHidden = true
        }

        updateUltraDarkOverlay(for: container)
        ensureLayerOrder(for: container)
    }

    private func ensureLayerOrder(for container: Container) {
        ensureUltraDarkOverlay(for: container)
        container.layer.insertSublayer(container.backgroundLayer, at: 0)
        container.layer.insertSublayer(container.backgroundToneLayer, above: container.backgroundLayer)
        if let overlay = container.ultraDarkOverlay {
            container.layer.insertSublayer(overlay, above: container.backgroundToneLayer)
        }

        if let dotRoot = container.dotRoot {
            if let overlay = container.ultraDarkOverlay {
                container.layer.insertSublayer(dotRoot, above: overlay)
            } else {
                container.layer.insertSublayer(dotRoot, above: container.backgroundToneLayer)
            }
            container.layer.insertSublayer(container.shapesRoot, above: dotRoot)
        } else {
            if let overlay = container.ultraDarkOverlay {
                container.layer.insertSublayer(container.shapesRoot, above: overlay)
            } else {
                container.layer.insertSublayer(container.shapesRoot, above: container.backgroundToneLayer)
            }
        }
    }

    private func ensureUltraDarkOverlay(for container: Container) {
        if container.ultraDarkOverlay == nil {
            let overlay = CALayer()
            overlay.frame = expandedBounds
            overlay.backgroundColor = NSColor.black.cgColor
            overlay.opacity = 0
            overlay.isHidden = true
            overlay.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            container.ultraDarkOverlay = overlay
        }
    }

    private func updateUltraDarkOverlay(for container: Container) {
        guard let overlay = container.ultraDarkOverlay else { return }
        overlay.frame = expandedBounds
        overlay.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let shouldShowOverlay = container.style == .image && isUltraDarkCover && harmonized.isDark
        if shouldShowOverlay {
            overlay.opacity = ultraDarkOverlayOpacity
            overlay.isHidden = false
        } else {
            overlay.opacity = 0
            overlay.isHidden = true
        }
    }

    private func chooseShapeImages(count: Int, rng: inout BKSeededRandom) -> [SelectedShape] {
        syncLoadedAssetsIfNeeded()
        guard !loadedShapes.images.isEmpty else { return [] }
        var indexed = Array(loadedShapes.images.enumerated())
        indexed.shuffle(using: &rng)
        if indexed.count >= count {
            return Array(indexed.prefix(count)).map { pair in
                SelectedShape(
                    image: pair.element,
                    scaleMultiplier: loadedShapes.scaleByIndex[pair.offset] ?? 1.0,
                    isEdgePinned: loadedShapes.edgePinnedIndices.contains(pair.offset)
                )
            }
        }
        var output = indexed.map { pair in
            SelectedShape(
                image: pair.element,
                scaleMultiplier: loadedShapes.scaleByIndex[pair.offset] ?? 1.0,
                isEdgePinned: loadedShapes.edgePinnedIndices.contains(pair.offset)
            )
        }
        while output.count < count {
            let randomIndex = Int(rng.next(in: 0..<Double(loadedShapes.images.count)))
            output.append(
                SelectedShape(
                    image: loadedShapes.images[randomIndex],
                    scaleMultiplier: loadedShapes.scaleByIndex[randomIndex] ?? 1.0,
                    isEdgePinned: loadedShapes.edgePinnedIndices.contains(randomIndex)
                )
            )
        }
        return output
    }

    private func targetShapeCount(using rng: inout BKSeededRandom) -> Int {
        switch resourceProfile {
        case .standard:
            return rng.nextInt(in: 10...16)
        case .cassetteForeground:
            return 10
        }
    }

    private func randomPinnedEdgePoint(side: CGFloat, rng: inout BKSeededRandom) -> CGPoint {
        let half = side * 0.5
        let overflowRatio = CGFloat(rng.next(in: 0.20...0.40))
        let overflow = half * overflowRatio

        let sidePick = rng.nextInt(in: 0...3)
        switch sidePick {
        case 0:  // top
            return CGPoint(
                x: CGFloat(rng.next(in: Double(-half)...Double(bounds.width + half))),
                y: bounds.height - half + overflow
            )
        case 1:  // bottom
            return CGPoint(
                x: CGFloat(rng.next(in: Double(-half)...Double(bounds.width + half))),
                y: half - overflow
            )
        case 2:  // left
            return CGPoint(
                x: half - overflow,
                y: CGFloat(rng.next(in: Double(-half)...Double(bounds.height + half)))
            )
        default:  // right
            return CGPoint(
                x: bounds.width - half + overflow,
                y: CGFloat(rng.next(in: Double(-half)...Double(bounds.height + half)))
            )
        }
    }

    private func nextShapeTint(
        from base: CGColor,
        rng: inout BKSeededRandom,
        hueJitterMax: CGFloat = 4,
        satJitterMax: CGFloat = 0.03,
        briJitterMax: CGFloat = 0.03
    ) -> CGColor {
        let hueRange: ClosedRange<Double> = -Double(hueJitterMax)...Double(hueJitterMax)
        let satRange: ClosedRange<Double> = -Double(satJitterMax)...Double(satJitterMax)
        let briRange: ClosedRange<Double> = -Double(briJitterMax)...Double(briJitterMax)
        let stabilized = BKColorEngine.stabilize(
            color: base,
            kind: .shape,
            palette: harmonized,
            hueJitter: CGFloat(rng.next(in: hueRange)),
            saturationJitter: CGFloat(rng.next(in: satRange)),
            brightnessJitter: CGFloat(rng.next(in: briRange))
        )
        return energizedLightShapeTint(stabilized, source: base)
    }

    private func energizedLightShapeTint(_ color: CGColor, source: CGColor? = nil) -> CGColor {
        guard !harmonized.isDark else { return color }
        guard var lch = BKPerceptualColorMath.lch(from: color) else {
            return color
        }
        let alpha = NSColor(cgColor: color)?.alphaComponent ?? 1
        let bgLCH = BKPerceptualColorMath.lchValues(from: harmonized.bgStops)
        let bgVariantColors = harmonized.bgVariants.flatMap { $0 }
        let bgVariantLCH = BKPerceptualColorMath.lchValues(
            from: bgVariantColors.isEmpty ? harmonized.bgStops : bgVariantColors
        )
        let backgroundMinL = bgLCH.map(\.l).min() ?? 0.915
        let backgroundMaxC = bgVariantLCH.map { $0.c }.max() ?? bgLCH.map { $0.c }.max() ?? 0.048
        let hasTrustedArtworkTint =
            currentAnalysis?.hasTrustedHueCandidate
            ?? (!harmonized.usesStrictNeutralRendering && !harmonized.isGrayscaleCover)

        if harmonized.usesStrictNeutralRendering || (harmonized.isGrayscaleCover && !hasTrustedArtworkTint) {
            // Light mode: neutral shapes must stay bright regardless of cover lightness.
            lch.l = min(max(lch.l, 0.750), max(0.770, min(0.862, backgroundMinL - 0.038)))
            lch.c = 0
            lch.h = 0
            return BKRenderingColorAdapter.cgColor(lch, alpha: alpha)
        }

        let sourceLCH = BKPerceptualColorMath.lch(from: source) ?? lch
        let neutralToneFromDarkField = hasTinyAccentOnDarkField
            && sourceLCH.c < 0.014
            && sourceLCH.l < 0.380
        let lightnessFloor: CGFloat
        let chromaCeiling: CGFloat
        if neutralToneFromDarkField {
            // Light mode: tiny-accent-on-dark-field shapes still need a bright floor.
            lightnessFloor = max(0.750, min(0.798, backgroundMinL - 0.072))
            chromaCeiling = min(0.046, max(0.020, backgroundMaxC * 0.52))
        } else {
            // Light mode: normal chromatic shapes. Floor aligned with shapeTone's
            // raised L band so shapes stay bright even on dark covers.
            lightnessFloor = max(0.752, min(0.825, backgroundMinL - 0.058))
            // Decouple from the muted background: let the ceiling follow the source
            // shape's own chroma (which shapeTone derived from the cover), so vivid
            // covers keep recognizable color instead of being flattened to gray.
            chromaCeiling = max(0.034, min(0.100, max(backgroundMaxC * 0.82, sourceLCH.c * 0.94)))
        }
        let lightnessUpper = max(lightnessFloor, min(0.862, backgroundMinL - 0.028))
        lch.l = min(max(lch.l, lightnessFloor), lightnessUpper)
        lch.c = min(
            lch.c,
            chromaCeiling,
            BKColorRiskPolicy.chromaCap(hue: lch.h, role: .stabilizedShape, isDark: false)
        )
        lch.h = BKColorRiskPolicy.adjustedHue(lch.h, role: .stabilizedShape)
        return BKRenderingColorAdapter.cgColor(lch, alpha: alpha)
    }

    private var hasTinyAccentOnDarkField: Bool {
        guard let analysis = currentAnalysis,
              !analysis.salientHighlightPalette.isEmpty,
              let largestSalient = analysis.salientHighlightAreaShares.max()
        else { return false }
        return analysis.dominantBrightness < 0.12
            && analysis.weightedLuma < 0.08
            && largestSalient <= 0.050
    }

    private func makeShapeTintPlan(
        count: Int,
        swatches: [CGColor],
        rng: inout BKSeededRandom
    ) -> [CGColor] {
        guard count > 0 else { return [] }
        let sourceSwatches = swatches.isEmpty ? harmonized.shapePool : swatches
        guard !sourceSwatches.isEmpty else {
            return Array(repeating: harmonized.dotBase, count: count)
        }

        var plan: [CGColor] = []
        plan.reserveCapacity(count)

        var ordered = sourceSwatches
        ordered.shuffle(using: &rng)
        for index in 0..<count {
            let base = ordered[index % ordered.count]
            plan.append(nextShapeTint(from: base, rng: &rng))
        }
        return plan
    }

    private func retintShapes(in container: Container?) {
        guard let container, !container.shapeLayers.isEmpty else { return }
        let swatchSeed = (container.seed == 0 ? rebuildSeed : container.seed) ^ 0xB3D2_AE5F_9E37_79B9
        let swatchResult = BKColorEngine.makeShapeSwatches(
            seed: swatchSeed,
            extracted: extractedPaletteForSwatches,
            fallback: BKArtBackgroundView.fallbackPalette,
            isDark: harmonized.isDark,
            analysis: currentAnalysis
        )
        container.shapeSwatches = swatchResult.colors.isEmpty ? harmonized.shapePool : swatchResult.colors
        container.swatchDiagnostics = swatchResult.diagnostics
        var rng = BKSeededRandom(
            seed: swatchSeed
                ^ UInt64(truncatingIfNeeded: container.shapeLayers.count)
        )
        let plan = makeShapeTintPlan(
            count: container.shapeLayers.count,
            swatches: container.shapeSwatches,
            rng: &rng
        )
        container.shapeTints = plan
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in container.shapeLayers.enumerated() {
            let tint = plan[index]
            if let fill = layer.sublayers?.first {
                fill.backgroundColor = tint
            }
            layer.opacity = 1.0
        }
        container.shapesRoot.opacity = 1.0
        CATransaction.commit()
    }

    private func randomEdgePoint(
        side: CGFloat,
        centerAvoidanceRect: CGRect?,
        rng: inout BKSeededRandom
    ) -> CGPoint {
        let minDimension = max(1, min(bounds.width, bounds.height))
        let safeSide = min(max(side, 1), max(1, minDimension - 2))
        let half = safeSide * 0.5
        let xLower = half
        let xUpper = max(half, bounds.width - half)
        let yLower = half
        let yUpper = max(half, bounds.height - half)
        let xSpan = max(0, xUpper - xLower)
        let ySpan = max(0, yUpper - yLower)
        let edgeBandX = min(max(24, bounds.width * 0.18), xSpan)
        let edgeBandY = min(max(24, bounds.height * 0.18), ySpan)

        func randomBetween(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let lo = min(a, b)
            let hi = max(a, b)
            return CGFloat(rng.next(in: Double(lo)...Double(hi)))
        }

        func biasedSpanPoint(
            lower: CGFloat,
            upper: CGFloat,
            centerAvoidanceRange: ClosedRange<CGFloat>?
        ) -> CGFloat {
            let span = max(0, upper - lower)
            guard span > 1 else { return lower }

            let edgeSegment = max(56, span * 0.22)
            let nearLeadingUpper = min(upper, lower + edgeSegment)
            let nearTrailingLower = max(lower, upper - edgeSegment)

            let farLeadingUpper: CGFloat
            let farTrailingLower: CGFloat
            if let centerAvoidanceRange {
                farLeadingUpper = max(lower, min(nearLeadingUpper, centerAvoidanceRange.lowerBound - 18))
                farTrailingLower = min(upper, max(nearTrailingLower, centerAvoidanceRange.upperBound + 18))
            } else {
                farLeadingUpper = nearLeadingUpper
                farTrailingLower = nearTrailingLower
            }

            let roll = rng.next(in: 0.0...1.0)
            if roll < 0.44, farLeadingUpper > lower + 1 {
                return randomBetween(lower, farLeadingUpper)
            }
            if roll < 0.88, upper > farTrailingLower + 1 {
                return randomBetween(farTrailingLower, upper)
            }
            if roll < 0.95 {
                return randomBetween(lower, upper)
            }

            let centerWidth = max(18, span * 0.12)
            let mid = (lower + upper) * 0.5
            return randomBetween(max(lower, mid - centerWidth * 0.5), min(upper, mid + centerWidth * 0.5))
        }

        let avoidanceXRange =
            centerAvoidanceRect.map { $0.minX...$0.maxX }
        let avoidanceYRange =
            centerAvoidanceRect.map { $0.minY...$0.maxY }

        for _ in 0..<28 {
            let sidePick = rng.next(in: 0.0..<1.0)
            let point: CGPoint
            if sidePick < 0.30 {
                point = CGPoint(
                    x: biasedSpanPoint(
                        lower: xLower,
                        upper: xUpper,
                        centerAvoidanceRange: avoidanceXRange
                    ),
                    y: randomBetween(yUpper - edgeBandY, yUpper)
                )
            } else if sidePick < 0.60 {
                point = CGPoint(
                    x: biasedSpanPoint(
                        lower: xLower,
                        upper: xUpper,
                        centerAvoidanceRange: avoidanceXRange
                    ),
                    y: randomBetween(yLower, yLower + edgeBandY)
                )
            } else if sidePick < 0.80 {
                point = CGPoint(
                    x: randomBetween(xLower, xLower + edgeBandX),
                    y: biasedSpanPoint(
                        lower: yLower,
                        upper: yUpper,
                        centerAvoidanceRange: avoidanceYRange
                    )
                )
            } else {
                point = CGPoint(
                    x: randomBetween(xUpper - edgeBandX, xUpper),
                    y: biasedSpanPoint(
                        lower: yLower,
                        upper: yUpper,
                        centerAvoidanceRange: avoidanceYRange
                    )
                )
            }

            let centerIsClear = centerAvoidanceRect?.contains(point) != true
            if centerIsClear {
                return point
            }
        }

        let fallbackX: CGFloat
        if let centerAvoidanceRect {
            fallbackX = min(
                max(half + 16, xLower),
                max(xLower, min(xUpper, centerAvoidanceRect.minX - 18))
            )
        } else {
            fallbackX = min(max(half + 16, xLower), xUpper)
        }
        let fallbackY = min(max(bounds.height - half - 16, yLower), yUpper)
        return CGPoint(
            x: fallbackX,
            y: fallbackY
        )
    }

    private func makeShapeState(
        basePosition: CGPoint,
        isEdgePinned: Bool,
        centerAvoidanceRect: CGRect?,
        rng: inout BKSeededRandom
    ) -> ShapeState {
        let phase = CGFloat(rng.next(in: 0...(Double.pi * 2)))
        let angle = CGFloat(rng.next(in: 0...(Double.pi * 2)))
        let angularSpeed = CGFloat(rng.next(in: -0.22...0.22))

        guard !isEdgePinned else {
            return ShapeState(
                basePosition: basePosition,
                driftX: 0,
                driftY: 0,
                phase: phase,
                phaseSpeed: 0,
                angle: angle,
                angularSpeed: angularSpeed
            )
        }

        for _ in 0..<10 {
            let driftX = CGFloat(rng.next(in: -12...12))
            let driftY = CGFloat(rng.next(in: -16...16))
            let motionRect = CGRect(
                x: basePosition.x - abs(driftX),
                y: basePosition.y - abs(driftY),
                width: abs(driftX) * 2,
                height: abs(driftY) * 2
            )
            if centerAvoidanceRect?.intersects(motionRect) == true {
                continue
            }

            return ShapeState(
                basePosition: basePosition,
                driftX: driftX,
                driftY: driftY,
                phase: phase,
                phaseSpeed: CGFloat(rng.next(in: 0.35...0.95)),
                angle: angle,
                angularSpeed: angularSpeed
            )
        }

        return ShapeState(
            basePosition: basePosition,
            driftX: 0,
            driftY: 0,
            phase: phase,
            phaseSpeed: 0,
            angle: angle,
            angularSpeed: angularSpeed
        )
    }

    private func makeTintedShapeLayer(image: CGImage, size: CGSize, tint: CGColor) -> CALayer {
        let root = CALayer()
        // Geometry Fix: bounds origin must be 0,0
        root.bounds = CGRect(origin: .zero, size: size)
        // Anchor point default is 0.5,0.5, so setting position externally works as center
        root.opacity = 1.0
        root.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        let fillLayer = CALayer()
        fillLayer.frame = root.bounds
        fillLayer.backgroundColor = tint
        fillLayer.opacity = 1.0

        let maskLayer = CALayer()
        maskLayer.frame = root.bounds
        maskLayer.contents = image
        maskLayer.contentsGravity = .resizeAspect
        maskLayer.contentsScale = root.contentsScale

        fillLayer.mask = maskLayer
        root.addSublayer(fillLayer)
        return root
    }

    private func fullscreenCircleImagesForSolidCircle() -> BKThemeAssets.FullscreenCircleLoadResult {
        if dotRenderStyle == .solidCircles,
           loadedFullscreenCircleImages.outerImages.count < 2
            || loadedFullscreenCircleImages.innerImages.count < 2 {
            let budget = currentAssetBudget().background
            loadedFullscreenCircleImages = assets.fullscreenCircleImages(maxPixel: budget)
            loadedFullscreenCircleMaxPixel = budget
        }
        return loadedFullscreenCircleImages
    }

    private func makeCircleImageLayer(
        image: CGImage,
        side: CGFloat,
        position: CGPoint,
        opacity: Float,
        zPosition: CGFloat
    ) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer.position = position
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.opacity = opacity
        layer.zPosition = zPosition
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.allowsEdgeAntialiasing = true
        layer.contents = image
        return layer
    }

    private nonisolated static func tintedCircleImage(
        from image: CGImage,
        tint: CGColor,
        role: FullscreenCircleLayerRole,
        isDark: Bool
    ) -> CGImage? {
        let nsColor = NSColor(cgColor: tint) ?? .white
        let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        let input = CIImage(cgImage: image)
        let source: CIImage
        if isDark {
            let brightness: CGFloat
            let contrast: CGFloat
            switch role {
            case .outer:
                brightness = -0.44
                contrast = 1.24
            case .inner:
                brightness = -0.18
                contrast = 1.10
            }
            source = input.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0.0,
                    kCIInputContrastKey: contrast,
                    kCIInputBrightnessKey: brightness,
                ]
            )
        } else {
            // Light mode: inner layer sits slightly darker than outer so the
            // two concentric circles read as depth (inner recedes) instead of
            // both being the same brightness.
            switch role {
            case .outer:
                source = input
            case .inner:
                source = input.applyingFilter(
                    "CIColorControls",
                    parameters: [
                        kCIInputBrightnessKey: -0.05,
                        kCIInputContrastKey: 1.02
                    ]
                )
            }
        }

        let componentCeiling: CGFloat = {
            guard !isDark else { return 1.0 }
            switch role {
            case .outer:
                return 0.955
            case .inner:
                return 0.965
            }
        }()
        let tintR = isDark ? rgb.redComponent : min(rgb.redComponent, componentCeiling)
        let tintG = isDark ? rgb.greenComponent : min(rgb.greenComponent, componentCeiling)
        let tintB = isDark ? rgb.blueComponent : min(rgb.blueComponent, componentCeiling)

        let tinted = source.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: componentCeiling - tintR, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: componentCeiling - tintG, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: componentCeiling - tintB, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: rgb.alphaComponent),
                "inputBiasVector": CIVector(x: tintR, y: tintG, z: tintB, w: 0),
            ]
        )

        let outputSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let rendered = circleTintContext.createCGImage(
            tinted,
            from: input.extent,
            format: .RGBA8,
            colorSpace: outputSpace
        )
        circleTintContext.clearCaches()
        return rendered
    }

    private func startTimersIfNeeded() {
        guard window != nil, !isPausedFrozen else { return }
        startShapeTimerIfNeeded()
        if !isTransitionInFlight {
            startBackgroundTimerIfNeeded()
            startDotTimerIfNeeded()
            resumeDeferredTransitionWorkIfNeeded()
        }
        if autoTransitionTimer == nil
            && speedTarget > 0.01
            && !isTransitionInFlight
            && toContainer == nil
            && pendingTransitionSeed == nil {
            scheduleNextAutoTransition()
        }
        if isTransitionInFlight && transitionClockSubscription == nil && speedTarget > 0.01 {
            startTransitionTimer()
        }
        updateClockActivity()
    }

    private func resumeDeferredTransitionWorkIfNeeded() {
        guard window != nil, speedTarget > 0.01 else { return }
        guard !isTransitionInFlight, toContainer == nil else { return }

        if pendingBoundsRebuild {
            pendingBoundsRebuild = false
            rebuildForCurrentBounds()
            return
        }

        if let pendingSeed = pendingTransitionSeed {
            _ = triggerTransition(seed: pendingSeed)
        }
    }

    private func startBackgroundTimerIfNeeded() {
        guard motionProfile.allowsAutomaticBackgroundPhaseCycling else { return }
        guard backgroundClockSubscription == nil else { return }
        backgroundClockSubscription = animationClock.backgroundPublisher
            .sink { [weak self] in
                self?.tickBackground()
            }
    }

    private func startDotTimerIfNeeded() {
        guard !isDotAnimationDriverRunning else { return }
        let publisher = motionProfile.usesHighRateDotClock(for: dotRenderStyle)
            ? animationClock.dotHighRatePublisher
            : animationClock.dotPublisher
        dotClockSubscription = publisher
            .sink { [weak self] in
                self?.tickDotAnimation()
            }
    }

    private func startShapeTimerIfNeeded() {
        guard shapeClockSubscription == nil else { return }
        shapeClockSubscription = animationClock.shapePublisher
            .sink { [weak self] in
                self?.tickShapes()
            }
    }

    private func stopTimers() {
        backgroundClockSubscription?.cancel()
        backgroundClockSubscription = nil
        shapeClockSubscription?.cancel()
        shapeClockSubscription = nil
        stopDotAnimationDriver()
        autoTransitionTimer?.cancel()
        autoTransitionTimer = nil
        stopTransitionTimer()
        speedRampClockSubscription?.cancel()
        speedRampClockSubscription = nil
        isTransitionInFlight = false
        isPausedFrozen = false
        updateClockActivity()
    }

    private func startTransitionTimer() {
        guard transitionClockSubscription == nil else { return }
        transitionClockSubscription = animationClock.transitionPublisher
            .sink { [weak self] in
                self?.tickTransitionMask()
            }
        updateClockActivity()
    }

    private func stopTransitionTimer() {
        transitionClockSubscription?.cancel()
        transitionClockSubscription = nil
        updateClockActivity()
    }

    private func transitionAssetsReadyForCurrentTarget() -> Bool {
        let budget = currentAssetBudget()
        let backgroundSourceIndices = desiredBackgroundSourceIndices()
        guard loadedBudget == budget else { return false }
        guard loadedBackgroundSourceIndices == backgroundSourceIndices else { return false }
        if !backgroundSourceIndices.isEmpty, loadedBackgrounds.isEmpty {
            return false
        }
        guard !loadedShapes.images.isEmpty else { return false }
        guard !loadedMaskFrames.isEmpty else { return false }
        return true
    }

    private func startTransitionAssetWarmupIfNeeded() {
        startAssetSnapshotLoadIfNeeded(
            budget: currentAssetBudget(),
            backgroundSourceIndices: desiredBackgroundSourceIndices(),
            includeMasks: true,
            applyBackgroundAssetMode: nil,
            resumePendingTransition: true
        )
    }

    private func startAssetSnapshotLoadIfNeeded(
        budget: BKThemeAssets.PixelBudget,
        backgroundSourceIndices: [Int],
        includeMasks: Bool,
        applyBackgroundAssetMode: BackgroundAssetMode?,
        resumePendingTransition: Bool
    ) {
        guard assetSnapshotTask == nil else { return }
        guard budget.background > 0 || budget.shape > 0 || budget.mask > 0 else { return }

        if includeMasks {
            maskWarmupTask?.cancel()
            maskWarmupTask = nil
        }

        assetSnapshotGeneration &+= 1
        let generation = assetSnapshotGeneration
        let assets = self.assets
        let shouldLoadFullscreenCircleImages = dotRenderStyle == .solidCircles

        assetSnapshotTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                let loadedBackgroundSet = Self.loadBackgrounds(
                    assets: assets,
                    sourceIndices: backgroundSourceIndices,
                    maxPixel: budget.background
                )
                let shapes = assets.shapes(maxPixel: budget.shape)
                let fullscreenCircleImages = shouldLoadFullscreenCircleImages
                    ? assets.fullscreenCircleImages(maxPixel: budget.background)
                    : BKThemeAssets.FullscreenCircleLoadResult()
                let maskFrames: [CGImage]
                if includeMasks {
                    maskFrames = assets.maskFrames(maxPixel: budget.mask)
                } else {
                    maskFrames = assets.cachedMaskFrames(maxPixel: budget.mask) ?? []
                }

                return AssetLoadSnapshotBox(
                    budget: budget,
                    backgroundImages: loadedBackgroundSet.images,
                    backgroundSourceIndices: loadedBackgroundSet.indices,
                    shapes: shapes,
                    maskFrames: maskFrames,
                    fullscreenCircleImages: fullscreenCircleImages
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.assetSnapshotTask = nil
                guard self.assetSnapshotGeneration == generation else { return }
                guard self.window != nil else { return }

                if let applyBackgroundAssetMode {
                    self.backgroundAssetMode = applyBackgroundAssetMode
                }

                guard
                    self.currentAssetBudget() == snapshot.budget,
                    self.desiredBackgroundSourceIndices() == backgroundSourceIndices
                else {
                    if resumePendingTransition, self.pendingTransitionSeed != nil {
                        self.startTransitionAssetWarmupIfNeeded()
                    }
                    return
                }

                self.applyAssetSnapshot(snapshot)
                self.applyCurrentBackgroundPhase()

                guard resumePendingTransition, let pendingSeed = self.pendingTransitionSeed else { return }
                let result = self.triggerTransition(seed: pendingSeed)
                if result != .deferred {
                    self.pendingTransitionSeed = nil
                }
            }
        }
    }

    private func applyAssetSnapshot(_ snapshot: AssetLoadSnapshotBox) {
        let backgroundsChanged =
            loadedBudget.background != snapshot.budget.background
            || loadedBackgroundSourceIndices != snapshot.backgroundSourceIndices

        if backgroundsChanged {
            cancelBackgroundRenderTasks()
        }

        loadedBudget = snapshot.budget
        loadedBackgrounds = snapshot.backgroundImages
        loadedBackgroundSourceIndices = snapshot.backgroundSourceIndices
        loadedShapes = snapshot.shapes
        loadedFullscreenCircleImages = snapshot.fullscreenCircleImages
        loadedFullscreenCircleMaxPixel = snapshot.budget.background
        loadedMaskFrames = snapshot.maskFrames
        tintedBackgroundCache.removeAllObjects()
        prewarmTintedBackgroundsIfNeeded()
    }

    private func startMaskWarmupIfNeeded(maskBudget: Int) {
        guard maskBudget > 0 else { return }
        if !loadedMaskFrames.isEmpty { return }
        if let cachedFrames = assets.cachedMaskFrames(maxPixel: maskBudget) {
            loadedMaskFrames = cachedFrames
            return
        }
        guard maskWarmupTask == nil else { return }

        let assets = self.assets
        maskWarmupTask = Task { [weak self] in
            let warmedFrames = await Task.detached(priority: .userInitiated) {
                await CGImageArrayBox(images: assets.maskFrames(maxPixel: maskBudget))
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.maskWarmupTask = nil
                guard self.loadedBudget.mask == maskBudget else { return }
                self.loadedMaskFrames = warmedFrames.images
                guard let pendingSeed = self.pendingTransitionSeed else { return }
                let result = self.triggerTransition(seed: pendingSeed)
                if result != .deferred {
                    self.pendingTransitionSeed = nil
                }
            }
        }
    }

    private var shouldFreezeVisualUpdates: Bool {
        speedTarget <= 0.01 || speedCurrent <= 0.01
    }

    private func startSpeedRampTimerIfNeeded() {
        guard speedRampClockSubscription == nil else { return }
        speedRampClockSubscription = animationClock.speedRampPublisher
            .sink { [weak self] in
                self?.tickSpeedRamp()
            }
        updateClockActivity()
    }

    private func stopSpeedRampTimer() {
        speedRampClockSubscription?.cancel()
        speedRampClockSubscription = nil
        updateClockActivity()
    }

    private func tickSpeedRamp() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTickTime, 1.0 / 240.0), 0.25)
        lastTickTime = now

        let diff = speedTarget - speedCurrent
        if abs(diff) > 0.0001 {
            let k = diff < 0 ? 4.0 : 5.5
            let alpha = 1 - exp(-k * dt)
            speedCurrent += diff * alpha
        }

        if abs(speedTarget - speedCurrent) < 0.01 {
            speedCurrent = speedTarget
            if speedTarget <= 0.01 {
                freezeAnimationTimers()
            } else {
                resumeAnimationTimersAfterFreeze()
            }
            stopSpeedRampTimer()
        }
    }

    private func freezeAnimationTimers() {
        guard !isPausedFrozen else { return }
        isPausedFrozen = true
        backgroundClockSubscription?.cancel()
        backgroundClockSubscription = nil
        shapeClockSubscription?.cancel()
        shapeClockSubscription = nil
        stopDotAnimationDriver()
        autoTransitionTimer?.cancel()
        autoTransitionTimer = nil
        stopTransitionTimer()
        updateClockActivity()
    }

    private func resumeAnimationTimersAfterFreeze() {
        guard isPausedFrozen else { return }
        isPausedFrozen = false
        startTimersIfNeeded()
    }

    private func enterTransitionPerformanceMode() {
        isTransitionInFlight = true
        startBackgroundTimerIfNeeded()
        startDotTimerIfNeeded()
        updateClockActivity()
    }

    private func exitTransitionPerformanceMode() {
        isTransitionInFlight = false

        if pendingBoundsRebuild {
            pendingBoundsRebuild = false
            rebuildForCurrentBounds()
        }

        updateClockActivity()
    }

    private func tickBackground() {
        guard backgroundClockSubscription != nil else { return }
        syncLoadedAssetsIfNeeded()
        let hasBackgrounds = !loadedBackgrounds.isEmpty
        guard hasBackgrounds else { return }
        let phaseStep = speedCurrent
        guard phaseStep > 0.0001 else { return }
        backgroundPhaseFloat += phaseStep
        let nextPhase = Int(floor(backgroundPhaseFloat))
        guard nextPhase != backgroundPhase else { return }
        backgroundPhase = nextPhase
        applyCurrentBackgroundPhase()
    }

    private func updateDotGradient(_ container: Container) {
        guard let gradient = container.dotGradient else { return }
        gradient.colors = dotGradientStops()
    }

    private func dotGradientStops() -> [CGColor] {
        guard harmonized.isDark,
              !harmonized.isGrayscaleCover,
              !harmonized.usesStrictNeutralRendering
        else {
            return harmonized.bgStops
        }
        return harmonized.bgStops.map { color in
            guard let nsColor = NSColor(cgColor: color),
                  var lch = OKColor.nsColorToOKLCH(nsColor),
                  lch.c >= 0.010
            else {
                return color
            }
            lch.c = min(0.105, max(lch.c + 0.010, lch.c * 1.18))
            lch.l = min(max(lch.l, 0.075), 0.32)
            return OKColor.okLCHToNSColor(lch, alpha: nsColor.alphaComponent).cgColor
        }
    }

    private var isUltraDarkCover: Bool {
        let luma = harmonized.imageCoverLuma
        return (luma < 0.36 && harmonized.areaDominantB < 0.30)
            || (luma < 0.30 && harmonized.grayScore > 0.70)
    }

    private func applyDotColor(to slot: DotSlot, colorSeed: UInt64) {
        var rng = BKSeededRandom(seed: colorSeed)
        let jitter = dotJitterBudget()
        let hueJitter = CGFloat(rng.next(in: jitter.hue))
        let satJitter = CGFloat(rng.next(in: jitter.saturation))
        let briJitter = CGFloat(rng.next(in: jitter.brightness))
        let finalColor = BKColorEngine.stabilize(
            color: harmonized.dotBase,
            kind: .dot,
            palette: harmonized,
            hueJitter: hueJitter,
            saturationJitter: satJitter,
            brightnessJitter: briJitter
        )
        var withAlpha = (NSColor(cgColor: finalColor) ?? .white).withAlphaComponent(0.90).cgColor
        if dotRenderStyle == .solidCircles {
            if let nsColor = NSColor(cgColor: finalColor),
               var lch = OKColor.nsColorToOKLCH(nsColor) {
                let targetAlpha: CGFloat
                if harmonized.usesStrictNeutralRendering {
                    if harmonized.isDark {
                        lch.l = min(max(lch.l * 0.88, 0.22), 0.48)
                        targetAlpha = 0.78
                    } else {
                        lch.l = min(max(lch.l, 0.58), 0.70)
                        targetAlpha = 0.86
                    }
                    lch.c = 0
                    lch.h = 0
                } else if harmonized.isDark {
                    // Dark mode: circle L close to the background band, keeping a
                    // subtle presence instead of swinging brighter/darker than it.
                    lch.l = ColorMath.clamp(lch.l * 0.58, 0.19, 0.30)
                    lch.c = min(0.085, lch.c * 0.55)
                    targetAlpha = 0.80
                } else {
                    // Light mode: L syncs with bright covers; chroma follows the
                    // cover's own saturation (capped) so vivid covers get vivid
                    // circles and muted covers get muted ones.
                    let brightBoost = ColorMath.clamp(
                        ((currentAnalysis?.brightAreaRatio ?? 0) - 0.35) / 0.40, 0, 1
                    )
                    lch.l = min(max(lch.l, 0.68 + brightBoost * 0.035), 0.765 + brightBoost * 0.025)
                    lch.c = min(0.130, lch.c * 0.98)
                    targetAlpha = 0.90
                }
                let adjustedNS = OKColor.okLCHToNSColor(lch, alpha: 1.0)
                withAlpha = adjustedNS.withAlphaComponent(targetAlpha).cgColor
            }
        }
        slot.color = withAlpha

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.cellBig?.fillColor = slot.color
        slot.cellSmall?.fillColor = slot.color
        if let layer = slot.circleOuterImageLayer,
           let source = slot.circleOuterImageSource,
           let tinted = Self.tintedCircleImage(
               from: source,
               tint: withAlpha,
               role: .outer,
               isDark: harmonized.isDark
           ) {
            layer.contents = tinted
            layer.opacity = harmonized.isDark ? 0.76 : 0.73
        }
        if let layer = slot.circleInnerImageLayer,
           let source = slot.circleInnerImageSource,
           let tinted = Self.tintedCircleImage(
               from: source,
               tint: withAlpha,
               role: .inner,
               isDark: harmonized.isDark
           ) {
            layer.contents = tinted
            layer.opacity = harmonized.isDark ? 0.82 : 0.76
        }
        CATransaction.commit()
    }

    private func retintDotSlots(in container: Container?) {
        guard let container, container.style == .dot else { return }
        for slot in container.dotSlots {
            applyDotColor(to: slot, colorSeed: slot.colorSeed)
        }
    }

    private func scheduleNextAutoTransition() {
        autoTransitionTimer?.cancel()

        // Dynamic interval: 20s if Dot (to let animation breathe), 15s if Image
        let interval: TimeInterval = (fromContainer?.style == .dot) ? 20.0 : 15.0

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: .infinity)  // One-shot logic effectively via reschedule
        timer.setEventHandler { [weak self] in
            self?.tickAutoTransition()
        }
        timer.resume()
        autoTransitionTimer = timer
    }

    private func tickAutoTransition() {
        autoTransitionTimer?.cancel()
        autoTransitionTimer = nil

        guard speedTarget > 0.01, speedCurrent > 0.01 else {
            return
        }
        let seed = nextTransitionSeed()
        let result = triggerTransition(seed: seed)
        if result == .ignored {
            scheduleNextAutoTransition()
        }
    }

    private func applyCurrentBackgroundPhase() {
        applyBackgroundPhase(to: fromContainer)
        applyBackgroundPhase(to: toContainer)
        publishCurrentSurfaceBackgroundColor()
    }

    private func applyBackgroundPhase(to container: Container?, allowSynchronousRender: Bool = true) {
        guard let container else { return }
        syncLoadedAssetsIfNeeded()

        var styleRng = BKSeededRandom(
            seed: rebuildSeed
                ^ UInt64(bitPattern: Int64(container.style.rawValue))
                ^ UInt64(bitPattern: Int64(backgroundPhase))
        )
        applyStyle(to: container, style: container.style, rng: &styleRng)

        if container.style == .dot {
            container.backgroundLayer.contents = nil
            container.backgroundLayer.backgroundColor = harmonized.bgStops.first ?? NSColor.black.cgColor
            container.shapesRoot.opacity = 1.0
            updateDotGradient(container)
            return
        }

        guard !loadedBackgrounds.isEmpty else { return }
        let displayIndex = backgroundPhase % loadedBackgrounds.count
        let sourceIndex = loadedBackgroundSourceIndices.isEmpty
            ? displayIndex
            : loadedBackgroundSourceIndices[min(displayIndex, loadedBackgroundSourceIndices.count - 1)]
        guard
            let image = resolvedBackgroundImage(
                sourceIndex: sourceIndex,
                variantIndex: container.bgVariantIndex,
                allowSynchronousRender: allowSynchronousRender
            )
        else {
            return
        }
        container.backgroundLayer.contentsGravity = .resizeAspectFill
        container.backgroundLayer.contentsScale =
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        container.backgroundLayer.contents = image
        container.shapesRoot.opacity = 1.0
        updateUltraDarkOverlay(for: container)

#if DEBUG
        assert(container.dotRoot == nil || container.dotRoot?.isHidden == true)
        assert(container.backgroundLayer.contents != nil)
        let minExpectedShapeCount = loadedShapes.images.isEmpty ? 0 : 10
        assert(container.shapesRoot.sublayers?.count ?? 0 >= minExpectedShapeCount)
#endif
    }

    private func tickShapes() {
        guard shapeClockSubscription != nil else { return }
        let dt = CGFloat((1.0 / 15.0) * speedCurrent)
        guard dt > 0.0001 else { return }
        updateShapes(for: fromContainer, dt: dt)
        updateShapes(for: toContainer, dt: dt)
    }

    private func tickDotAnimation() {
        guard dotClockSubscription != nil else { return }
        let dt = motionProfile.dotFrameInterval(for: dotRenderStyle) * speedCurrent
        guard dt > 0.0001 else { return }
        tickDotBackground(for: fromContainer, dt: dt)
        tickDotBackground(for: toContainer, dt: dt)
    }

    private var isDotAnimationDriverRunning: Bool {
        dotClockSubscription != nil
    }

    private func stopDotAnimationDriver() {
        dotClockSubscription?.cancel()
        dotClockSubscription = nil
    }

    private func updateShapes(for container: Container?, dt: CGFloat) {
        guard let container else { return }
        guard !container.shapeLayers.isEmpty else { return }
        guard container.shapeLayers.count == container.shapeStates.count else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for index in container.shapeLayers.indices {
            var state = container.shapeStates[index]
            state.phase += state.phaseSpeed * dt
            state.angle += state.angularSpeed * dt

            let x = state.basePosition.x + cos(state.phase) * state.driftX
            let y = state.basePosition.y + sin(state.phase * 0.93) * state.driftY

            let layer = container.shapeLayers[index]
            layer.position = CGPoint(x: x, y: y)
            layer.transform = CATransform3DMakeRotation(state.angle, 0, 0, 1)

            container.shapeStates[index] = state
        }

        CATransaction.commit()
    }

    private func tickTransitionMask() {
        guard transitionClockSubscription != nil else { return }
        guard let toContainer, let maskLayer = transitionMaskLayer else { return }
        let maskFrames = resolvedMaskFrames()
        guard !maskFrames.isEmpty else {
            abortTransitionKeepingCurrent(pendingSeed: rebuildSeed)
            return
        }

        let progressStep = speedCurrent
        guard progressStep > 0.0001 else { return }
        maskFrameProgress += progressStep
        let nextFrameIndex = Int(floor(maskFrameProgress))
        if nextFrameIndex >= maskFrames.count {
            finalizeTransition()
            return
        }
        guard nextFrameIndex != maskFrameIndex else { return }
        maskFrameIndex = nextFrameIndex

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.contents = maskFrames[maskFrameIndex]
        CATransaction.commit()

        toContainer.layer.mask = maskLayer
    }

    private func abortTransitionKeepingCurrent(pendingSeed: UInt64?) {
        toContainer?.layer.mask = nil
        toContainer?.layer.removeFromSuperlayer()
        toContainer = nil
        transitionMaskLayer?.contents = nil
        transitionMaskLayer?.removeFromSuperlayer()
        transitionMaskLayer = nil
        maskFrameIndex = 0
        maskFrameProgress = 0
        stopTransitionTimer()
        exitTransitionPerformanceMode()

        if let pendingSeed {
            pendingTransitionSeed = pendingSeed
            startTransitionAssetWarmupIfNeeded()
        }
        startTimersIfNeeded()
    }

    private func finalizeTransition() {
        guard let next = toContainer else {
            stopTransitionTimer()
            exitTransitionPerformanceMode()
            return
        }
        next.layer.mask = nil
        transitionMaskLayer?.contents = nil
        transitionMaskLayer = nil
        fromContainer?.layer.removeFromSuperlayer()
        fromContainer = next
        toContainer = nil
        commitStyleHistory(next.style)
        stopTransitionTimer()
        exitTransitionPerformanceMode()
        publishCurrentSurfaceBackgroundColor()
        startTimersIfNeeded()
    }

    private func updateClockActivity() {
        var channels: BackgroundAnimationClock.Channels = []

        if backgroundClockSubscription != nil {
            channels.insert(.background)
        }
        if shapeClockSubscription != nil {
            channels.insert(.shape)
        }
        if dotClockSubscription != nil {
            channels.insert(
                motionProfile.usesHighRateDotClock(for: dotRenderStyle)
                    ? .dotHighRate
                    : .dot
            )
        }
        if transitionClockSubscription != nil {
            channels.insert(.transition)
        }
        if speedRampClockSubscription != nil {
            channels.insert(.speedRamp)
        }

        if channels.isEmpty {
            if let clockLeaseID {
                animationClock.release(clockLeaseID)
                self.clockLeaseID = nil
            }
        } else if let clockLeaseID {
            animationClock.updateLease(clockLeaseID, channels: channels)
        } else {
            clockLeaseID = animationClock.acquire(channels: channels)
        }
    }

    private func cancelBackgroundRenderTasks() {
        backgroundRenderGeneration &+= 1
        backgroundRenderTasks.values.forEach { $0.cancel() }
        backgroundRenderTasks.removeAll(keepingCapacity: false)
    }

    private func publishCurrentSurfaceBackgroundColor() {
        // Defer publishing to avoid "Publishing changes from within view updates" warnings
        // This method is called from layout(), updateNSView(), and animation callbacks
        let publishedTrackID = trackID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.backgroundController?.setCurrentSurfaceDescriptor(
                usesDotBackground: self.fromContainer?.style == .dot,
                variantIndex: self.fromContainer?.bgVariantIndex,
                for: publishedTrackID
            )
            self.backgroundController?.setCurrentSurfaceBackgroundColor(
                self.resolvedDisplayedBackgroundColor(for: self.fromContainer),
                for: publishedTrackID
            )
        }
    }

    private func resolvedDisplayedBackgroundColor(for container: Container?) -> NSColor? {
        guard let container else { return nil }

        if container.style == .dot {
            if let cgColor = container.backgroundLayer.backgroundColor {
                return NSColor(cgColor: cgColor)
            }
            return harmonized.bgStops.first.flatMap { NSColor(cgColor: $0) }
        }

        if let cgColor = container.backgroundToneLayer.backgroundColor {
            return NSColor(cgColor: cgColor)
        }

        return harmonized.bgStops.first.flatMap { NSColor(cgColor: $0) }
    }

    private struct ImageVariantTuning: Sendable {
        let avgChroma: CGFloat
        let hueSpread: CGFloat
        let richScore: CGFloat
        let mapAlpha: CGFloat
        let originalSaturation: CGFloat
        let composedSaturationBoost: CGFloat
    }

    private func resolvedBackgroundImage(
        sourceIndex: Int,
        variantIndex: Int,
        allowSynchronousRender: Bool = true
    ) -> CGImage? {
        let sourceLookupIndex: Int
        if let matchedIndex = loadedBackgroundSourceIndices.firstIndex(of: sourceIndex) {
            sourceLookupIndex = matchedIndex
        } else if sourceIndex >= 0, sourceIndex < loadedBackgrounds.count {
            sourceLookupIndex = sourceIndex
        } else {
            return nil
        }
        let toneVariants = backgroundToneVariants()
        let safeVariantIndex = min(max(0, variantIndex), max(0, toneVariants.count - 1))
        let cacheKey =
            "\(paletteSignature)|bg:\(loadedBudget.background)|variant:\(safeVariantIndex)|source:\(sourceIndex)"

        if let cached = tintedBackgroundCache.object(forKey: cacheKey as NSString) {
            return cached.image
        }

        let sourceImage = loadedBackgrounds[sourceLookupIndex]
        let toneStops = toneVariants.isEmpty ? BKArtBackgroundView.fallbackPalette : toneVariants[safeVariantIndex]
        guard allowSynchronousRender else {
            scheduleTintedBackgroundRenderIfNeeded(
                cacheKey: cacheKey,
                sourceImage: sourceImage,
                toneStops: toneStops
            )
            return nil
        }
        if let rendered = renderTintedBackgroundNow(
            cacheKey: cacheKey,
            sourceImage: sourceImage,
            toneStops: toneStops
        ) {
            return rendered
        }

        scheduleTintedBackgroundRenderIfNeeded(
            cacheKey: cacheKey,
            sourceImage: sourceImage,
            toneStops: toneStops
        )
        return nil
    }

    private func renderTintedBackgroundNow(
        cacheKey: String,
        sourceImage: CGImage,
        toneStops: [NSColor]
    ) -> CGImage? {
        let toneComponents = toneStops.map(ToneStopComponent.init(color:))
        let tuning = imageVariantTuning(for: toneStops)
        guard
            let rendered = Self.makeTintedBackgroundImage(
                from: sourceImage,
                toneStops: toneComponents,
                tuning: tuning,
                isDark: harmonized.isDark
            )
        else {
            return nil
        }

        tintedBackgroundCache.setObject(
            CGImageBox(image: rendered),
            forKey: cacheKey as NSString,
            cost: max(1, rendered.bytesPerRow * rendered.height)
        )
        return rendered
    }

    private func scheduleTintedBackgroundRenderIfNeeded(
        cacheKey: String,
        sourceImage: CGImage,
        toneStops: [NSColor]
    ) {
        guard backgroundRenderTasks[cacheKey] == nil else { return }

        let paletteSignatureAtRequest = paletteSignature
        let backgroundBudget = loadedBudget.background
        let toneComponents = toneStops.map(ToneStopComponent.init(color:))
        let tuning = imageVariantTuning(for: toneStops)
        let isDark = harmonized.isDark
        let sourceBox = CGImageBox(image: sourceImage)
        let renderGeneration = backgroundRenderGeneration

        backgroundRenderTasks[cacheKey] = Task { [weak self] in
            let sourceImage = sourceBox.image
            let rendered = await Task.detached(priority: .utility) {
                Self.makeTintedBackgroundImage(
                    from: sourceImage,
                    toneStops: toneComponents,
                    tuning: tuning,
                    isDark: isDark
                )
            }.value
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.backgroundRenderTasks.removeValue(forKey: cacheKey)
                guard self.backgroundRenderGeneration == renderGeneration else { return }
                guard self.window != nil else { return }
                guard self.fromContainer != nil || self.toContainer != nil else { return }
                guard self.paletteSignature == paletteSignatureAtRequest else { return }
                guard self.loadedBudget.background == backgroundBudget else { return }
                guard let rendered else { return }
                let boxed = CGImageBox(image: rendered)

                self.tintedBackgroundCache.setObject(
                    boxed,
                    forKey: cacheKey as NSString,
                    cost: max(1, rendered.bytesPerRow * rendered.height)
                )
                self.applyCurrentBackgroundPhase()
            }
        }
    }

    private func prewarmTintedBackgroundsIfNeeded() {
        guard !loadedBackgrounds.isEmpty else { return }
        let toneVariants = backgroundToneVariants()
        let effectiveVariants = toneVariants.isEmpty ? [BKArtBackgroundView.fallbackPalette] : toneVariants

        for (lookupIndex, sourceImage) in loadedBackgrounds.enumerated() {
            guard lookupIndex < loadedBackgroundSourceIndices.count else { continue }
            let sourceIndex = loadedBackgroundSourceIndices[lookupIndex]

            for variantIndex in effectiveVariants.indices {
                let cacheKey =
                    "\(paletteSignature)|bg:\(loadedBudget.background)|variant:\(variantIndex)|source:\(sourceIndex)"
                if tintedBackgroundCache.object(forKey: cacheKey as NSString) != nil {
                    continue
                }
                scheduleTintedBackgroundRenderIfNeeded(
                    cacheKey: cacheKey,
                    sourceImage: sourceImage,
                    toneStops: effectiveVariants[variantIndex]
                )
            }
        }
    }

    private nonisolated static func makeTintedBackgroundImage(
        from image: CGImage,
        toneStops: [ToneStopComponent],
        tuning: ImageVariantTuning,
        isDark: Bool
    ) -> CGImage? {
        guard let mapImage = makeColorMapImage(colors: toneStops) else { return nil }
        let input = CIImage(cgImage: image)
        let grayscale = input.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.08,
                kCIInputBrightnessKey: 0.0,
            ]
        )

        let mapped = grayscale.applyingFilter(
            "CIColorMap",
            parameters: ["inputGradientImage": mapImage]
        )
        let mappedSoftAlpha = mapped.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: tuning.mapAlpha)
            ]
        )
        let desaturatedOriginal = input.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: tuning.originalSaturation,
                kCIInputContrastKey: 1.10,
                kCIInputBrightnessKey: 0.0,
            ]
        )
        var composed = mappedSoftAlpha.applyingFilter(
            "CISourceOverCompositing",
            parameters: [kCIInputBackgroundImageKey: desaturatedOriginal]
        )
        if abs(tuning.composedSaturationBoost - 1.0) > 0.01 {
            composed = composed.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: tuning.composedSaturationBoost,
                    kCIInputContrastKey: 1.02,
                    kCIInputBrightnessKey: 0.0,
                ]
            )
        }
        let finalImage = toneMap(image: composed, isDark: isDark)
        let outputSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let rendered = backgroundRenderContext.createCGImage(
            finalImage,
            from: input.extent,
            format: .RGBA8,
            colorSpace: outputSpace
        )
        backgroundRenderContext.clearCaches()
        return rendered
    }

    private nonisolated static let backgroundRenderContext = CIContext(
        options: [.cacheIntermediates: false]
    )

    private nonisolated static func toneMap(image: CIImage, isDark: Bool) -> CIImage {
        image.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 1.0,
                kCIInputContrastKey: isDark ? 1.010 : 1.015,
                kCIInputBrightnessKey: isDark ? 0.004 : 0.032,
            ]
        )
    }

    private func imageVariantTuning(for colors: [NSColor]) -> ImageVariantTuning {
        let lches = colors.compactMap { OKColor.nsColorToOKLCH($0) }

        guard !lches.isEmpty else {
            return ImageVariantTuning(
                avgChroma: 0.020,
                hueSpread: 0,
                richScore: 0,
                mapAlpha: 0.66,
                originalSaturation: 0.22,
                composedSaturationBoost: 1.0
            )
        }

        let avgC = lches.map(\.c).reduce(0, +) / CGFloat(lches.count)
        let chromaticHues = lches
            .filter { $0.c >= 0.006 }
            .map { ($0.h * 360).truncatingRemainder(dividingBy: 360) }
        var hueSpread: CGFloat = 0
        if chromaticHues.count > 1 {
            for i in 0..<(chromaticHues.count - 1) {
                for j in (i + 1)..<chromaticHues.count {
                    var d = abs(chromaticHues[i] - chromaticHues[j]).truncatingRemainder(dividingBy: 360)
                    if d > 180 { d = 360 - d }
                    hueSpread = max(hueSpread, d)
                }
            }
        }

        let richScore = max(
            0,
            min(
                1,
                (avgC - 0.020) / 0.075 * 0.6 + (hueSpread / 90) * 0.4
            )
        )
        let colorfulnessEvidence = currentAnalysis?.colorfulness ?? min(1, avgC * 3.0)
        let lowColorCover = colorfulnessEvidence >= 0.08 && colorfulnessEvidence < 0.22
        let lowSatLift = harmonized.isGrayscaleCover
            ? 0
            : max(0, min(1, (0.070 - max(avgC, colorfulnessEvidence * 0.10)) / 0.050))
        var mapAlpha = max(0.68, min(0.90, lerp(0.70, 0.86, t: richScore) + lowSatLift * 0.04))
        var originalSaturation = max(
            harmonized.isGrayscaleCover ? 0.02 : 0.08,
            min(0.30, lerp(0.10, 0.24, t: richScore) - lowSatLift * 0.06)
        )
        var composedBoost: CGFloat = harmonized.isGrayscaleCover
            ? lerp(0.90, 1.00, t: richScore)
            : max(1.02, min(1.18, lerp(1.02, 1.14, t: richScore) + lowSatLift * 0.06))
        if lowColorCover && !harmonized.isGrayscaleCover {
            mapAlpha = max(mapAlpha, 0.84)
            originalSaturation = min(originalSaturation, 0.12)
            composedBoost = max(composedBoost, 1.16)
        }
        let hasTrustedTint =
            currentAnalysis?.hasTrustedHueCandidate
            ?? (!harmonized.isGrayscaleCover && avgC >= 0.018)
        if harmonized.isDark, hasTrustedTint, !harmonized.isGrayscaleCover {
            let chromaEvidence = max(avgC * 3.0, colorfulnessEvidence)
            let vividT = max(0, min(1, (chromaEvidence - 0.10) / 0.34))
            let darkT = max(0, min(1, (0.36 - harmonized.imageCoverLuma) / 0.30))
            mapAlpha = max(mapAlpha, min(0.96, lerp(0.88, 0.95, t: vividT) + darkT * 0.02))
            originalSaturation = min(originalSaturation, lerp(0.10, 0.055, t: vividT))
            composedBoost = max(
                composedBoost,
                min(1.34, 1.14 + vividT * 0.14 + darkT * 0.06)
            )
        }

        return ImageVariantTuning(
            avgChroma: avgC,
            hueSpread: hueSpread,
            richScore: richScore,
            mapAlpha: mapAlpha,
            originalSaturation: originalSaturation,
            composedSaturationBoost: composedBoost
        )
    }

    private func backgroundToneVariants() -> [[NSColor]] {
        let variantStops = !harmonized.bgVariants.isEmpty ? harmonized.bgVariants : [harmonized.bgStops]
        let fallback = BKArtBackgroundView.fallbackPalette

        let normalized = variantStops.map { stops -> [NSColor] in
            let base = stops.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
            let colors = base.isEmpty
                ? [fallback[0].usingColorSpace(.deviceRGB) ?? fallback[0]]
                : base
            if harmonized.isGrayscaleCover {
                return colors
            }
            return colors.map { enforceImageToneFloor($0) }
        }.filter { !$0.isEmpty }

        return normalized.isEmpty
            ? [[fallback[0].usingColorSpace(.deviceRGB) ?? fallback[0]]]
            : normalized
    }

    private func enforceImageToneFloor(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        guard var lch = OKColor.nsColorToOKLCH(rgb) else { return color }
        let hasTrustedTint =
            currentAnalysis?.hasTrustedHueCandidate
            ?? (!harmonized.usesStrictNeutralRendering && !harmonized.isGrayscaleCover && lch.c >= 0.012)
        let neutral = harmonized.usesStrictNeutralRendering
            || harmonized.isGrayscaleCover
            || !hasTrustedTint

        if neutral {
            lch.c = min(lch.c, harmonized.isDark ? 0.012 : 0.010)
            if lch.c <= 0.0005 {
                lch.h = 0
            }
        } else {
            let colorfulnessEvidence = currentAnalysis?.colorfulness ?? min(1, lch.c * 3.0)
            let brightBoost = ColorMath.clamp(
                ((currentAnalysis?.brightAreaRatio ?? 0) - 0.35) / 0.40, 0, 1
            )
            let floorC: CGFloat
            if harmonized.isDark {
                floorC = ColorMath.clamp(0.020 + colorfulnessEvidence * 0.10, 0.024, 0.070)
            } else {
                // Fade the chroma floor for bright near-white covers so a light
                // cover does not get an oversaturated background.
                let nearWhiteFade = brightBoost * ColorMath.clamp(1 - lch.c * 5.0, 0, 1)
                floorC = ColorMath.clamp(
                    (0.030 + colorfulnessEvidence * 0.13) * (1 - nearWhiteFade * 0.45),
                    0.020,
                    0.105
                )
            }
            lch.c = min(
                max(lch.c, floorC),
                BKColorRiskPolicy.chromaCap(hue: lch.h, role: .backgroundAtmosphere, isDark: harmonized.isDark)
            )
            lch.h = BKColorRiskPolicy.adjustedHue(lch.h, role: .backgroundAtmosphere)
        }

        if harmonized.isDark {
            // Narrowed L band: raise the floor and lower the ceiling so the
            // gradient-mapped image no longer crushes shadows to dead black
            // while still keeping a light/dark hierarchy.
            let floorL: CGFloat = isUltraDarkCover ? 0.128 : 0.168
            let ceilingL: CGFloat = isUltraDarkCover ? 0.240 : 0.310
            lch.l = min(max(lch.l, floorL), ceilingL)
        } else {
            let brightBoost = ColorMath.clamp(
                ((currentAnalysis?.brightAreaRatio ?? 0) - 0.35) / 0.40, 0, 1
            )
            lch.l = min(max(lch.l, 0.900 + brightBoost * 0.025), 0.970 + brightBoost * 0.015)
        }
        let adjusted = ColorRenderingAdapter.makeNSColor(
            OKLCHColor(lch, alpha: Double(rgb.alphaComponent)),
            target: .displayP3
        )
        return energizedDarkImageTone(adjusted)
    }

    private func energizedDarkImageTone(_ color: NSColor) -> NSColor {
        guard harmonized.isDark,
              !harmonized.isGrayscaleCover
        else {
            return color
        }

        guard let lch = OKColor.nsColorToOKLCH(color),
              lch.c >= 0.018
        else {
            return color
        }
        let hasTrustedTint =
            currentAnalysis?.hasTrustedHueCandidate
            ?? (!harmonized.usesStrictNeutralRendering && lch.c >= 0.018)
        guard hasTrustedTint else { return color }

        let chromaEvidence = max(currentAnalysis?.colorfulness ?? 0, lch.c * 3.0)
        let vividT = max(0, min(1, (chromaEvidence - 0.12) / 0.36))
        let lowLightT = max(0, min(1, (0.38 - lch.l) / 0.24))
        let floorC = min(0.070, lch.c + lowLightT * vividT * 0.026)
        let scaledC = max(floorC, lch.c * (1.0 + lowLightT * (0.30 + vividT * 0.20)))
        let shouldered = OKColor.chromaSoftShoulder(
            OKColor.OKLCH(l: lch.l, c: scaledC, h: lch.h),
            ceiling: 0.116,
            softness: 0.034
        )
        return ColorRenderingAdapter.makeNSColor(
            OKLCHColor(shouldered, alpha: Double(color.alphaComponent)),
            target: .displayP3
        )
    }

    private nonisolated static func makeColorMapImage(colors: [ToneStopComponent]) -> CIImage? {
        guard !colors.isEmpty else { return nil }
        let width = 256
        let height = 1
        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let stopCount = colors.count

        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            let color: ToneStopComponent
            if stopCount == 1 {
                color = colors[0]
            } else {
                let segmentCount = stopCount - 1
                let position = t * CGFloat(segmentCount)
                let left = min(segmentCount - 1, max(0, Int(floor(position))))
                let right = min(segmentCount, left + 1)
                let localT = position - CGFloat(left)
                color = blend(colors[left], colors[right], t: localT)
            }

            let idx = x * bytesPerPixel
            data[idx + 0] = UInt8(clamp(color.red) * 255.0)
            data[idx + 1] = UInt8(clamp(color.green) * 255.0)
            data[idx + 2] = UInt8(clamp(color.blue) * 255.0)
            data[idx + 3] = UInt8(clamp(color.alpha) * 255.0)
        }

        guard
            let provider = CGDataProvider(data: Data(data) as CFData),
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private nonisolated static func blend(
        _ lhs: ToneStopComponent,
        _ rhs: ToneStopComponent,
        t: CGFloat
    ) -> ToneStopComponent {
        let p = max(0, min(1, t))
        return ToneStopComponent(
            red: lhs.red + (rhs.red - lhs.red) * p,
            green: lhs.green + (rhs.green - lhs.green) * p,
            blue: lhs.blue + (rhs.blue - lhs.blue) * p,
            alpha: lhs.alpha + (rhs.alpha - lhs.alpha) * p
        )
    }

    private nonisolated static func clamp(_ value: CGFloat) -> CGFloat {
        min(1.0, max(0.0, value))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        let p = max(0, min(1, t))
        return a + (b - a) * p
    }

    private func nextTransitionSeed() -> UInt64 {
        transitionSeedCounter &+= 1
        return rebuildSeed &+ (transitionSeedCounter &* 0x9E37_79B9_7F4A_7C15)
    }

    private var expandedBounds: CGRect {
        bounds.insetBy(dx: -1.0, dy: -1.0)
    }

    private func syncLoadedAssetsIfNeeded() {
        syncLoadedAssetsIfNeeded(allowMaskWarmup: false)
    }

    private func syncLoadedAssetsIfNeeded(allowMaskWarmup: Bool) {
        guard assetSnapshotTask == nil else { return }

        let budget = currentAssetBudget()
        let targetBackgroundIndices = desiredBackgroundSourceIndices()
        let backgroundBudgetChanged = budget.background != loadedBudget.background
        let shapeBudgetChanged = budget.shape != loadedBudget.shape
        let maskBudgetChanged = budget.mask != loadedBudget.mask
        let circleBudgetChanged =
            dotRenderStyle == .solidCircles
            && budget.background != loadedFullscreenCircleMaxPixel
        let backgroundSetChanged = targetBackgroundIndices != loadedBackgroundSourceIndices

        guard backgroundBudgetChanged
            || shapeBudgetChanged
            || maskBudgetChanged
            || circleBudgetChanged
            || backgroundSetChanged
        else {
            if allowMaskWarmup {
                startMaskWarmupIfNeeded(maskBudget: budget.mask)
            }
            return
        }

        if backgroundBudgetChanged || backgroundSetChanged {
            cancelBackgroundRenderTasks()
        }
        if maskBudgetChanged {
            maskWarmupTask?.cancel()
            maskWarmupTask = nil
            loadedMaskFrames.removeAll(keepingCapacity: false)
        }

        loadedBudget = budget
        let loadedBackgroundSet = loadBackgrounds(
            sourceIndices: targetBackgroundIndices,
            maxPixel: budget.background
        )
        loadedBackgrounds = loadedBackgroundSet.images
        loadedBackgroundSourceIndices = loadedBackgroundSet.indices
        if shapeBudgetChanged || loadedShapes.images.isEmpty {
            loadedShapes = assets.shapes(maxPixel: budget.shape)
        }
        if dotRenderStyle == .solidCircles,
           circleBudgetChanged
            || loadedFullscreenCircleImages.outerImages.isEmpty
            || loadedFullscreenCircleImages.innerImages.isEmpty {
            loadedFullscreenCircleImages = assets.fullscreenCircleImages(maxPixel: budget.background)
            loadedFullscreenCircleMaxPixel = budget.background
        }
        loadedMaskFrames = assets.cachedMaskFrames(maxPixel: budget.mask) ?? []
        tintedBackgroundCache.removeAllObjects()
        prewarmTintedBackgroundsIfNeeded()
        if allowMaskWarmup {
            startMaskWarmupIfNeeded(maskBudget: budget.mask)
        }
    }

    private func resolvedMaskFrames() -> [CGImage] {
        if loadedMaskFrames.isEmpty {
            loadedMaskFrames = assets.cachedMaskFrames(maxPixel: loadedBudget.mask) ?? []
        }
        return loadedMaskFrames
    }

    private func currentAssetBudget() -> BKThemeAssets.PixelBudget {
        let fullBudget = fullResolutionAssetBudget()
        let background = backgroundAssetMode == .fullSet
            ? fullBudget.background
            : min(fullBudget.background, initialBackgroundBudgetCap)
        return BKThemeAssets.PixelBudget(
            background: background,
            shape: fullBudget.shape,
            mask: fullBudget.mask
        )
    }

    private func fullResolutionAssetBudget() -> BKThemeAssets.PixelBudget {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let longestEdge = max(bounds.width, bounds.height)
        let nativePixel = Int(max(1, (longestEdge * scale).rounded()))
        let backgroundCap = resourceProfile == .cassetteForeground ? 1_024 : 1_536
        let backgroundFloor = resourceProfile == .cassetteForeground ? 640 : 960
        let shapeCap = resourceProfile == .cassetteForeground ? 320 : 512
        let shapeFloor = resourceProfile == .cassetteForeground ? 192 : 256
        let maskCap = resourceProfile == .cassetteForeground ? 512 : 768
        let maskFloor = resourceProfile == .cassetteForeground ? 384 : 512
        let background = min(max(nativePixel, backgroundFloor), backgroundCap)
        let shapeDivisor = resourceProfile == .cassetteForeground ? 4 : 3
        let shape = min(max(background / shapeDivisor, shapeFloor), shapeCap)
        let mask = min(max(background / 2, maskFloor), maskCap)
        return BKThemeAssets.PixelBudget(background: background, shape: shape, mask: mask)
    }

    private func desiredBackgroundSourceIndices() -> [Int] {
        let count = assets.backgroundCount
        guard count > 0 else { return [] }

        switch backgroundAssetMode {
        case .currentPhaseLowRes:
            return [backgroundPhase % count]
        case .fullSet:
            return Array(0..<count)
        }
    }

    private func loadBackgrounds(sourceIndices: [Int], maxPixel: Int) -> (images: [CGImage], indices: [Int]) {
        Self.loadBackgrounds(
            assets: assets,
            sourceIndices: sourceIndices,
            maxPixel: maxPixel
        )
    }

    private nonisolated static func loadBackgrounds(
        assets: BKThemeAssets,
        sourceIndices: [Int],
        maxPixel: Int
    ) -> (images: [CGImage], indices: [Int]) {
        guard !sourceIndices.isEmpty, maxPixel > 0 else { return ([], []) }

        if sourceIndices.count == assets.backgroundCount {
            let images = assets.backgrounds(maxPixel: maxPixel)
            let availableIndices = Array(0..<min(images.count, sourceIndices.count))
            return (images, availableIndices)
        }

        var images: [CGImage] = []
        var resolvedIndices: [Int] = []
        for sourceIndex in sourceIndices {
            guard let image = assets.background(at: sourceIndex, maxPixel: maxPixel) else { continue }
            images.append(image)
            resolvedIndices.append(sourceIndex)
        }
        return (images, resolvedIndices)
    }

    private func promoteBackgroundAssetsToFullSet() {
        backgroundAssetMode = .fullSet
        logDiagnostics(
            "promoteBackgroundAssetsToFullSet budget=\(debugBudgetDescription(currentAssetBudget())) fullBudget=\(debugBudgetDescription(fullResolutionAssetBudget())) trackID=\(trackID?.uuidString ?? "nil")"
        )
    }

    private func cancelInitialResourceUpgradeTask() {
        initialResourceUpgradeTask?.cancel()
        initialResourceUpgradeTask = nil
    }

    private func scheduleInitialResourceUpgradeIfNeeded() {
        guard backgroundAssetMode == .currentPhaseLowRes else { return }
        guard initialResourceUpgradeTask == nil else { return }
        guard window != nil else { return }
        guard fromContainer != nil else { return }

        initialResourceUpgradeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.initialResourceUpgradeTask = nil
                }
            }

            try? await Task.sleep(nanoseconds: self.initialBackgroundUpgradeDelay)
            guard !Task.isCancelled else { return }
            guard self.shouldAutoPromoteBackgroundsOnIdle else { return }

            await MainActor.run {
                guard self.window != nil else { return }
                guard self.fromContainer != nil else { return }
                guard self.backgroundAssetMode == .currentPhaseLowRes else { return }

                self.logDiagnostics(
                    "scheduleFullAssetPromotion budget=\(self.debugBudgetDescription(self.fullResolutionAssetBudget())) trackID=\(self.trackID?.uuidString ?? "nil")"
                )
                self.startAssetSnapshotLoadIfNeeded(
                    budget: self.fullResolutionAssetBudget(),
                    backgroundSourceIndices: Array(0..<self.assets.backgroundCount),
                    includeMasks: self.shouldAutoWarmMasksOnIdle,
                    applyBackgroundAssetMode: .fullSet,
                    resumePendingTransition: true
                )
            }
        }
    }

    private func releaseHeavyResources() {
        cancelInitialResourceUpgradeTask()
        rebuildDebounceTask?.cancel()
        rebuildDebounceTask = nil
        maskWarmupTask?.cancel()
        maskWarmupTask = nil
        assetSnapshotTask?.cancel()
        assetSnapshotTask = nil
        assetSnapshotGeneration &+= 1
        cancelBackgroundRenderTasks()
        pendingTransitionSeed = nil
        release(container: fromContainer)
        release(container: toContainer)
        fromContainer = nil
        toContainer = nil
        transitionMaskLayer?.removeAllAnimations()
        transitionMaskLayer?.contents = nil
        transitionMaskLayer?.removeFromSuperlayer()
        transitionMaskLayer = nil
        loadedBackgrounds.removeAll(keepingCapacity: false)
        loadedBackgroundSourceIndices.removeAll(keepingCapacity: false)
        loadedShapes = BKThemeAssets.ShapeLoadResult(images: [], scaleByIndex: [:], edgePinnedIndices: [])
        loadedFullscreenCircleImages = BKThemeAssets.FullscreenCircleLoadResult()
        loadedFullscreenCircleMaxPixel = 0
        loadedMaskFrames.removeAll(keepingCapacity: false)
        loadedBudget = BKThemeAssets.PixelBudget(background: 0, shape: 0, mask: 0)
        backgroundAssetMode = .currentPhaseLowRes
        tintedBackgroundCache.removeAllObjects()
        assets.purgeTransientCaches()
        Self.backgroundRenderContext.clearCaches()
        layer?.removeAllAnimations()
        layer?.mask = nil
        layer?.contents = nil
        layer?.sublayers?.forEach { sublayer in
            sublayer.removeAllAnimations()
            sublayer.mask = nil
            sublayer.contents = nil
            sublayer.removeFromSuperlayer()
        }
        layer?.sublayers = nil
    }

    private func ensureRootLayerIfNeeded() {
        if !wantsLayer {
            wantsLayer = true
        }
        if layer == nil {
            let rootLayer = CALayer()
            rootLayer.masksToBounds = true
            rootLayer.backgroundColor = NSColor.black.cgColor
            layer = rootLayer
        } else {
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
    }

    private func tearDownRootLayer() {
        lastLayoutSize = .zero
        pendingBoundsRebuild = false
        layer?.removeAllAnimations()
        layer?.mask = nil
        layer?.contents = nil
        layer?.sublayers?.forEach { sublayer in
            sublayer.removeAllAnimations()
            sublayer.mask = nil
            sublayer.contents = nil
            sublayer.removeFromSuperlayer()
        }
        layer?.sublayers = nil
        layer = nil
        wantsLayer = false
        removeFromSuperviewWithoutNeedingDisplay()
    }

    private func release(container: Container?) {
        guard let container else { return }
        container.layer.removeAllAnimations()
        container.backgroundLayer.removeAllAnimations()
        container.backgroundToneLayer.removeAllAnimations()
        container.layer.mask = nil
        container.backgroundLayer.contents = nil
        container.backgroundToneLayer.contents = nil
        container.shapeLayers.forEach { shape in
            shape.removeAllAnimations()
            shape.sublayers?.forEach { sublayer in
                sublayer.removeAllAnimations()
                sublayer.mask = nil
                sublayer.contents = nil
            }
            shape.contents = nil
            shape.removeFromSuperlayer()
        }
        container.dotSlots.forEach { slot in
            slot.cellBig = nil
            slot.cellSmall = nil
            slot.maskBig = nil
            slot.maskSmall = nil
            slot.circleOuterImageLayer = nil
            slot.circleInnerImageLayer = nil
            slot.circleOuterImageSource = nil
            slot.circleInnerImageSource = nil
            slot.rootLayer.removeAllAnimations()
            slot.rootLayer.sublayers?.forEach { sublayer in
                sublayer.removeAllAnimations()
                sublayer.mask = nil
                sublayer.contents = nil
            }
            slot.rootLayer.removeFromSuperlayer()
        }
        container.dotSlots.removeAll(keepingCapacity: false)
        container.dotRoot?.removeAllAnimations()
        container.dotRoot?.sublayers?.forEach { sublayer in
            sublayer.removeAllAnimations()
            sublayer.mask = nil
            sublayer.contents = nil
        }
        container.dotRoot?.removeFromSuperlayer()
        container.dotRoot = nil
        container.dotGradient = nil
        container.ultraDarkOverlay?.removeAllAnimations()
        container.ultraDarkOverlay?.contents = nil
        container.ultraDarkOverlay?.removeFromSuperlayer()
        container.ultraDarkOverlay = nil
        container.layer.sublayers?.forEach { sublayer in
            sublayer.removeAllAnimations()
            sublayer.mask = nil
            sublayer.contents = nil
        }
        container.layer.removeFromSuperlayer()
    }

    private func logLifecycle(_ event: String) {
        #if DEBUG
            guard Self.lifecycleLoggingEnabled else { return }
            switch event {
            case "init":
                Self.liveInstanceCount += 1
            case "deinit":
                Self.liveInstanceCount = max(0, Self.liveInstanceCount - 1)
            default:
                break
            }
            Log.info(
                "[BKArtBackgroundLayerView] \(event) live=\(Self.liveInstanceCount)",
                category: .perf
            )
        #endif
    }

    private func logDiagnostics(_ message: @autoclosure () -> String) {
        guard Self.fullscreenDiagnosticsEnabled else { return }
        Log.info("[FullscreenBK] \(message())", category: .perf)
    }

    private func debugBudgetDescription(_ budget: BKThemeAssets.PixelBudget) -> String {
        "bg=\(budget.background) shape=\(budget.shape) mask=\(budget.mask)"
    }

    private var initialBackgroundBudgetCap: Int {
        resourceProfile == .cassetteForeground ? 640 : 960
    }

    private var initialBackgroundUpgradeDelay: UInt64 {
        resourceProfile == .cassetteForeground ? 900_000_000 : 180_000_000
    }

    private var initialMaskWarmupDelay: UInt64 {
        resourceProfile == .cassetteForeground ? 700_000_000 : 420_000_000
    }

    private var shouldAutoWarmMasksOnIdle: Bool {
        resourceProfile == .standard
    }

    private var shouldAutoPromoteBackgroundsOnIdle: Bool {
        resourceProfile == .standard
    }

    private static func paletteSignature(for colors: [CGColor]) -> String {
        colors
            .map { color in
                let c = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) ?? NSColor.white
                return String(
                    format: "%.4f_%.4f_%.4f_%.4f",
                    c.redComponent,
                    c.greenComponent,
                    c.blueComponent,
                    c.alphaComponent
                )
            }
            .joined(separator: "|")
    }

    // MARK: - Dot Background Implementation

    private func setupDotBackground(in container: Container, rng: inout BKSeededRandom) {
        let root = CALayer()
        root.frame = expandedBounds
        root.masksToBounds = true
        container.dotRoot = root
        container.layer.insertSublayer(root, above: container.backgroundToneLayer)

        // A) Gradient Background (Shared)
        let gradient = CAGradientLayer()
        gradient.frame = root.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        container.dotGradient = gradient
        root.addSublayer(gradient)
        updateDotGradient(container)

        // Initialize first Slot.
        createAndAddSlot(
            to: container,
            rng: &rng,
            overlapT: initialDotLeadInOverlap,
            initialIdleDelay: 0
        )
        ensureLayerOrder(for: container)
    }

    private func createAndAddSlot(
        to container: Container,
        rng: inout BKSeededRandom,
        overlapT: Double? = nil,
        initialIdleDelay: TimeInterval? = nil
    ) {
        guard let root = container.dotRoot else { return }

        let baseSize = max(bounds.width, bounds.height)
        let anim = makeDotAnimState(
            baseSize: baseSize,
            rng: &rng,
            overlapT: overlapT,
            initialIdleDelay: initialIdleDelay
        )

        // 2. Create Slot
        let dotBaseRadius = baseSize * CGFloat(
            rng.next(in: dotBaseRadiusRange())
        )
        let slot = DotSlot(anim: anim, baseRadius: dotBaseRadius, colorSeed: rng.nextUInt64())
        slot.radiusBig = CGFloat(rng.next(in: 5.0...6.2))
        slot.radiusSmall = CGFloat(rng.next(in: 3.0...4.0))
        slot.maskBaseRadiusBig = max(1, dotBaseRadius * 0.75)
        slot.maskBaseRadiusSmall = max(1, dotBaseRadius)
        slot.outerRotationBaseAngle = CGFloat(rng.next(in: 0...(Double.pi * 2)))
        let outerRotationDirection: CGFloat = rng.next(in: 0.0...1.0) >= 0.5 ? 1 : -1
        slot.outerRotationTravelAngle =
            outerRotationDirection * CGFloat(rng.next(in: (Double.pi * 0.12)...(Double.pi * 0.50)))
        slot.innerRotationBaseAngle = CGFloat(rng.next(in: 0...(Double.pi * 2)))
        let innerRotationDirection: CGFloat = rng.next(in: 0.0...1.0) >= 0.5 ? 1 : -1
        slot.innerRotationTravelAngle =
            innerRotationDirection * CGFloat(rng.next(in: (Double.pi * 0.82)...(Double.pi * 1.85)))

        slot.rootLayer.frame = root.bounds

        // 3. Build Layer Tree for this Slot
        if dotRenderStyle == .solidCircles {
            let circleImages = fullscreenCircleImagesForSolidCircle()
            if !circleImages.outerImages.isEmpty, !circleImages.innerImages.isEmpty {
                let outerIndex = Int(rng.nextUInt64() % UInt64(circleImages.outerImages.count))
                let innerIndex = Int(rng.nextUInt64() % UInt64(circleImages.innerImages.count))
                let outerSource = circleImages.outerImages[outerIndex]
                let innerSource = circleImages.innerImages[innerIndex]
                let side = slot.maskBaseRadiusSmall * 2
                let outerLayer = makeCircleImageLayer(
                    image: outerSource,
                    side: side,
                    position: anim.start,
                    opacity: 0.75,
                    zPosition: 0
                )
                let innerLayer = makeCircleImageLayer(
                    image: innerSource,
                    side: side,
                    position: anim.start,
                    opacity: 0.72,
                    zPosition: 1
                )
                outerLayer.setAffineTransform(CGAffineTransform(rotationAngle: slot.outerRotationBaseAngle))
                innerLayer.setAffineTransform(CGAffineTransform(rotationAngle: slot.innerRotationBaseAngle))
                slot.rootLayer.addSublayer(outerLayer)
                slot.rootLayer.addSublayer(innerLayer)
                slot.circleOuterImageLayer = outerLayer
                slot.circleInnerImageLayer = innerLayer
                slot.circleOuterImageSource = outerSource
                slot.circleInnerImageSource = innerSource
            } else {
                let solid1 = CAShapeLayer()
                solid1.bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: slot.maskBaseRadiusBig * 2,
                    height: slot.maskBaseRadiusBig * 2
                )
                solid1.path = CGPath(ellipseIn: solid1.bounds, transform: nil)
                solid1.position = anim.start
                solid1.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                solid1.fillColor = NSColor(white: 0.3, alpha: 1.0).cgColor
                solid1.opacity = 0.68
                solid1.zPosition = 1
                slot.rootLayer.addSublayer(solid1)
                slot.cellBig = solid1
                slot.maskBig = solid1

                let solid2 = CAShapeLayer()
                solid2.bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: slot.maskBaseRadiusSmall * 2,
                    height: slot.maskBaseRadiusSmall * 2
                )
                solid2.path = CGPath(ellipseIn: solid2.bounds, transform: nil)
                solid2.position = anim.start
                solid2.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                solid2.fillColor = NSColor(white: 0.3, alpha: 1.0).cgColor
                solid2.opacity = 0.48
                solid2.zPosition = 0
                slot.rootLayer.addSublayer(solid2)
                slot.cellSmall = solid2
                solid2.shadowColor = NSColor.black.cgColor
                solid2.shadowOpacity = 0.18
                solid2.shadowRadius = max(12, slot.maskBaseRadiusSmall * 0.12)
                solid2.shadowOffset = .zero
                slot.maskSmall = solid2
            }
        } else {
            let dotSpacing: CGFloat = 30
            let cols = Int(baseSize / dotSpacing) + 6
            let rows = Int(baseSize / dotSpacing) + 6

            // Grid 1 (Big)
            let grid1 = CALayer()
            grid1.frame = root.bounds
            let cell1 = addDotGrid(
                to: grid1, cols: cols, rows: rows, spacing: dotSpacing, radius: slot.radiusBig,
                opacity: 0.90)
            slot.rootLayer.addSublayer(grid1)
            slot.cellBig = cell1

            let mask1 = CAShapeLayer()
            mask1.fillColor = NSColor.black.cgColor
            mask1.bounds = CGRect(
                x: 0,
                y: 0,
                width: slot.maskBaseRadiusBig * 2,
                height: slot.maskBaseRadiusBig * 2
            )
            mask1.path = CGPath(ellipseIn: mask1.bounds, transform: nil)
            mask1.position = anim.start
            mask1.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            grid1.mask = mask1
            slot.maskBig = mask1

            // Grid 2 (Small)
            let grid2 = CALayer()
            grid2.frame = root.bounds
            let cell2 = addDotGrid(
                to: grid2, cols: cols, rows: rows, spacing: dotSpacing, radius: slot.radiusSmall,
                opacity: 0.50)
            slot.rootLayer.addSublayer(grid2)
            slot.cellSmall = cell2

            let mask2 = CAShapeLayer()
            mask2.fillColor = NSColor.black.cgColor
            mask2.bounds = CGRect(
                x: 0,
                y: 0,
                width: slot.maskBaseRadiusSmall * 2,
                height: slot.maskBaseRadiusSmall * 2
            )
            mask2.path = CGPath(ellipseIn: mask2.bounds, transform: nil)
            mask2.position = anim.start
            mask2.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            grid2.mask = mask2
            slot.maskSmall = mask2
        }

        if dotRenderStyle == .solidCircles {
            applyDotColor(to: slot, colorSeed: slot.colorSeed)
        }

        // 4. Add to container.
        root.addSublayer(slot.rootLayer)
        container.dotSlots.append(slot)
    }

    private func makeDotAnimState(
        baseSize: CGFloat,
        rng: inout BKSeededRandom,
        overlapT: Double?,
        initialIdleDelay: TimeInterval?
    ) -> DotAnimState {
        let dotAvoidanceRect = activeAvoidanceRect?.insetBy(dx: -34, dy: -24)
        let radius = baseSize * dotOffscreenTravelRadiusFactor

        for _ in 0..<18 {
            let start = randomOffscreenPoint(radius: radius, rng: &rng, marginMul: 1.05)
            let end = randomOffscreenPoint(radius: radius, rng: &rng, marginMul: 1.45)
            let cp1 = randomControlPoint(avoidanceRect: dotAvoidanceRect, rng: &rng)
            let cp2 = randomControlPoint(avoidanceRect: dotAvoidanceRect, rng: &rng)
            let duration = rng.next(in: dotTravelDurationRange())
            var leadIn = overlapT ?? rng.next(in: dotLeadInOverlapRange())
            if duration > dotLongDurationThreshold {
                leadIn = max(dotLeadInMinimum, leadIn - dotLongDurationLeadInAdjustment)
            }

            if pathAvoidsAvoidanceRect(
                start: start,
                cp1: cp1,
                cp2: cp2,
                end: end,
                avoidanceRect: dotAvoidanceRect
            ) {
                let idleDelay = max(0, initialIdleDelay ?? rng.next(in: dotIdleDelayRange()))
                return DotAnimState(
                    motion: .idle(idleDelay),
                    start: start,
                    cp1: cp1,
                    cp2: cp2,
                    end: end,
                    duration: duration,
                    leadInOverlapT: leadIn
                )
            }
        }

        return fallbackDotAnimState(
            baseSize: baseSize,
            avoidanceRect: dotAvoidanceRect,
            rng: &rng,
            overlapT: overlapT,
            initialIdleDelay: initialIdleDelay
        )
    }

    private func fallbackDotAnimState(
        baseSize: CGFloat,
        avoidanceRect: CGRect?,
        rng: inout BKSeededRandom,
        overlapT: Double?,
        initialIdleDelay: TimeInterval?
    ) -> DotAnimState {
        let radius = baseSize * dotOffscreenTravelRadiusFactor
        let leftLaneMaxX = avoidanceRect.map { max(bounds.minX + 120, $0.minX - 56) }
            ?? (bounds.width * 0.40)
        let laneX = min(max(bounds.width * 0.18, CGFloat(120)), leftLaneMaxX)
        let topY = bounds.maxY + radius * 1.1
        let bottomY = bounds.minY - radius * 1.3
        let startFromTop = rng.next(in: 0.0...1.0) >= 0.5
        let start = CGPoint(x: laneX, y: startFromTop ? topY : bottomY)
        let end = CGPoint(
            x: min(bounds.maxX - 80, laneX + CGFloat(rng.next(in: -60...90))),
            y: startFromTop ? bottomY : topY
        )
        let cpInset = max(140, bounds.width * 0.12)
        let cp1 = CGPoint(
            x: min(leftLaneMaxX, laneX + cpInset * 0.35),
            y: startFromTop ? bounds.maxY * 0.78 : bounds.maxY * 0.22
        )
        let cp2 = CGPoint(
            x: min(leftLaneMaxX, laneX + cpInset),
            y: startFromTop ? bounds.maxY * 0.26 : bounds.maxY * 0.74
        )
        let duration = rng.next(in: dotFallbackTravelDurationRange())
        let idleDelay = max(0, initialIdleDelay ?? rng.next(in: dotFallbackIdleDelayRange()))
        let leadIn = overlapT ?? rng.next(in: dotFallbackLeadInOverlapRange())
        return DotAnimState(
            motion: .idle(idleDelay),
            start: start,
            cp1: cp1,
            cp2: cp2,
            end: end,
            duration: duration,
            leadInOverlapT: leadIn
        )
    }

    private func randomControlPoint(
        avoidanceRect: CGRect?,
        rng: inout BKSeededRandom
    ) -> CGPoint {
        for _ in 0..<16 {
            let point = CGPoint(
                x: CGFloat(rng.next(in: Double(bounds.minX)...Double(bounds.maxX))),
                y: CGFloat(rng.next(in: Double(bounds.minY)...Double(bounds.maxY)))
            )
            if avoidanceRect?.contains(point) != true {
                return point
            }
        }

        if let avoidanceRect {
            return CGPoint(
                x: max(bounds.minX + 80, avoidanceRect.minX - 80),
                y: bounds.midY
            )
        }

        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func pathAvoidsAvoidanceRect(
        start: CGPoint,
        cp1: CGPoint,
        cp2: CGPoint,
        end: CGPoint,
        avoidanceRect: CGRect?
    ) -> Bool {
        guard let avoidanceRect else { return true }
        if avoidanceRect.contains(cp1) || avoidanceRect.contains(cp2) {
            return false
        }

        for sampleIndex in 1...20 {
            let t = Double(sampleIndex) / 20.0
            let point = cubicBezier(t: t, p0: start, p1: cp1, p2: cp2, p3: end)
            if avoidanceRect.contains(point) {
                return false
            }
        }

        return true
    }

    private struct JitterBudget {
        let hue: ClosedRange<Double>
        let saturation: ClosedRange<Double>
        let brightness: ClosedRange<Double>
    }

    private func dotJitterBudget() -> JitterBudget {
        if harmonized.usesStrictNeutralRendering {
            return JitterBudget(hue: 0...0, saturation: 0...0, brightness: -0.025...0.025)
        }
        if harmonized.isGrayscaleCover {
            return JitterBudget(hue: -6...6, saturation: -0.02...0.02, brightness: -0.02...0.02)
        }
        if harmonized.isNearGray {
            return JitterBudget(hue: -12...12, saturation: -0.03...0.03, brightness: -0.03...0.03)
        }
        switch harmonized.complexity {
        case .monochrome:
            return JitterBudget(hue: -6...6, saturation: -0.02...0.02, brightness: -0.02...0.02)
        case .low:
            return JitterBudget(hue: -3...3, saturation: -0.03...0.03, brightness: -0.03...0.03)
        case .medium, .high:
            return JitterBudget(hue: -6...6, saturation: -0.04...0.04, brightness: -0.04...0.04)
        }
    }

    @discardableResult
    private func addDotGrid(
        to parent: CALayer, cols: Int, rows: Int, spacing: CGFloat, radius: CGFloat, opacity: Float,
        offset: CGPoint = .zero
    ) -> CAShapeLayer {
        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        // Default neutral color to avoid white flash before slot tint is assigned.
        dot.fillColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        dot.opacity = opacity

        let repX = CAReplicatorLayer()
        repX.instanceCount = cols
        repX.instanceTransform = CATransform3DMakeTranslation(spacing, 0, 0)
        repX.addSublayer(dot)

        let repY = CAReplicatorLayer()
        repY.instanceCount = rows
        repY.instanceTransform = CATransform3DMakeTranslation(0, spacing, 0)
        repY.addSublayer(repX)

        repY.position = CGPoint(x: -spacing * 2 + offset.x, y: -spacing * 2 + offset.y)
        parent.addSublayer(repY)

        return dot
    }

    private func tickDotBackground(for container: Container?, dt: Double) {
        guard let container, container.style == .dot, container.dotRoot != nil else { return }
        var slotsToRemove: [Int] = []
        var shouldSpawnNext = false
        var lastSlotRng: BKSeededRandom?

        // Iterate slots
        for (index, slot) in container.dotSlots.enumerated() {
            switch slot.anim.motion {
            case .idle(let remaining):
                let next = remaining - dt
                if next <= 0 {
                    applyDotColor(to: slot, colorSeed: slot.colorSeed)
                    slot.anim.motion = .moving(0)
                } else {
                    slot.anim.motion = .idle(next)
                }

            case .moving(let t):
                let step = dt / slot.anim.duration
                let nextT = t + step

                // LEAD-IN LOGIC: If this is the "latest" slot, check overlap overlapT
                if index == container.dotSlots.count - 1 {
                    if nextT >= slot.anim.leadInOverlapT && container.dotSlots.count < 2 {
                        shouldSpawnNext = true
                        let s = UInt64(bitPattern: Int64(slot.anim.end.x * 100 + slot.anim.end.y))
                        lastSlotRng = BKSeededRandom(seed: s ^ 0xDEAD_BEEF)
                    }
                }

                if nextT >= 1.0 {
                    slotsToRemove.append(index)
                    slot.anim.motion = .moving(1.0)
                } else {
                    slot.anim.motion = .moving(nextT)
                }

                // Visuals
                let pos = cubicBezier(
                    t: min(1.0, nextT), p0: slot.anim.start, p1: slot.anim.cp1, p2: slot.anim.cp2,
                    p3: slot.anim.end)

                var scale: CGFloat = 1.0
                if nextT < dotScaleRampInEnd {
                    let progress = nextT / dotScaleRampInEnd
                    scale = dotMinimumScale + (1.0 - dotMinimumScale) * easeOutQuint(progress)
                } else if nextT > dotScaleRampOutStart {
                    let progress = (nextT - dotScaleRampOutStart) / (1.0 - dotScaleRampOutStart)
                    scale = 1.0 - (1.0 - dotMinimumScale) * easeInQuint(progress)
                }

                let currentR =
                    (slot.baseRadius > 0
                        ? slot.baseRadius : max(bounds.width, bounds.height) * 0.30) * scale

                CATransaction.begin()
                CATransaction.setDisableActions(true)

                if slot.circleOuterImageLayer != nil || slot.circleInnerImageLayer != nil {
                    let targetR = max(1, currentR)
                    let imageScale = targetR / max(1, slot.maskBaseRadiusSmall)
                    let rotationT = Self.circleRotationProgress(at: min(1.0, max(0.0, nextT)))
                    if let outerLayer = slot.circleOuterImageLayer {
                        let angle = slot.outerRotationBaseAngle
                            + slot.outerRotationTravelAngle * CGFloat(rotationT)
                        outerLayer.position = pos
                        outerLayer.setAffineTransform(
                            CGAffineTransform(rotationAngle: angle).scaledBy(x: imageScale, y: imageScale)
                        )
                    }
                    if let innerLayer = slot.circleInnerImageLayer {
                        let angle = slot.innerRotationBaseAngle
                            + slot.innerRotationTravelAngle * CGFloat(rotationT)
                        innerLayer.position = pos
                        innerLayer.setAffineTransform(
                            CGAffineTransform(rotationAngle: angle).scaledBy(x: imageScale, y: imageScale)
                        )
                    }
                } else if let mask0 = slot.maskBig {
                    let targetR0 = max(1, currentR * 0.75)
                    let scale0 = targetR0 / max(1, slot.maskBaseRadiusBig)
                    mask0.position = pos
                    mask0.setAffineTransform(CGAffineTransform(scaleX: scale0, y: scale0))
                }
                if let mask1 = slot.maskSmall {
                    let targetR1 = max(1, currentR)
                    let scale1 = targetR1 / max(1, slot.maskBaseRadiusSmall)
                    mask1.position = pos
                    mask1.setAffineTransform(CGAffineTransform(scaleX: scale1, y: scale1))
                }

                CATransaction.commit()
            }
        }

        if shouldSpawnNext {
            var rng = lastSlotRng ?? BKSeededRandom(seed: UInt64(Date().timeIntervalSince1970))
            createAndAddSlot(to: container, rng: &rng)
        }

        for i in slotsToRemove.reversed() {
            let slot = container.dotSlots[i]
            slot.rootLayer.removeFromSuperlayer()
            container.dotSlots.remove(at: i)
        }

        // Safety: If somehow empty, spawn one
        if container.dotSlots.isEmpty {
            var rng = BKSeededRandom(seed: UInt64(Date().timeIntervalSince1970))
            createAndAddSlot(to: container, rng: &rng, initialIdleDelay: 0)
        }
    }

    private func cubicBezier(t: Double, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)
        -> CGPoint
    {
        let oneMinusT = 1.0 - t
        let t2 = t * t
        let t3 = t2 * t
        let oneMinusT2 = oneMinusT * oneMinusT
        let oneMinusT3 = oneMinusT2 * oneMinusT

        let x =
            oneMinusT3 * p0.x + 3 * oneMinusT2 * t * p1.x + 3 * oneMinusT * t2 * p2.x + t3 * p3.x
        let y =
            oneMinusT3 * p0.y + 3 * oneMinusT2 * t * p1.y + 3 * oneMinusT * t2 * p2.y + t3 * p3.y
        return CGPoint(x: x, y: y)
    }

    private func easeOutQuint(_ x: Double) -> Double {
        return 1.0 - pow(1.0 - x, 5)
    }

    private func easeInQuint(_ x: Double) -> Double {
        return x * x * x * x * x
    }

    private nonisolated static func circleRotationProgress(at t: Double) -> Double {
        let p = min(1.0, max(0.0, t))
        let edgeWeightedIntegral = (4.0 / 3.0) * p * p * p - 2.0 * p * p + p
        let totalIntegral = 1.0 / 3.0
        let baseVelocity = 0.55
        let edgeBoost = 1.25
        return (baseVelocity * p + edgeBoost * edgeWeightedIntegral)
            / (baseVelocity + edgeBoost * totalIntegral)
    }

    private func randomOffscreenPoint(
        radius: CGFloat, rng: inout BKSeededRandom, marginMul: CGFloat = 1.5
    ) -> CGPoint {
        // Pick a side: 0=top, 1=bottom, 2=left, 3=right
        let side = rng.nextInt(in: 0...3)
        // Explicitly force far offscreen.
        let margin = radius * marginMul

        switch side {
        case 0:  // Top
            return CGPoint(
                x: CGFloat(
                    rng.next(in: Double(bounds.minX - margin)...Double(bounds.maxX + margin))),
                y: bounds.maxY + margin
            )
        case 1:  // Bottom
            return CGPoint(
                x: CGFloat(
                    rng.next(in: Double(bounds.minX - margin)...Double(bounds.maxX + margin))),
                y: bounds.minY - margin
            )
        case 2:  // Left
            return CGPoint(
                x: bounds.minX - margin,
                y: CGFloat(
                    rng.next(in: Double(bounds.minY - margin)...Double(bounds.maxY + margin)))
            )
        default:  // Right
            return CGPoint(
                x: bounds.maxX + margin,
                y: CGFloat(
                    rng.next(in: Double(bounds.minY - margin)...Double(bounds.maxY + margin)))
            )
        }
    }

    private func dotBaseRadiusRange() -> ClosedRange<Double> {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.26...0.34
        case .solidCircles:
            return 0.34...0.44
        }
    }

    private var dotOffscreenTravelRadiusFactor: CGFloat {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.30
        case .solidCircles:
            return 0.40
        }
    }

    private func dotTravelDurationRange() -> ClosedRange<Double> {
        switch dotRenderStyle {
        case .dotGrid:
            return 12.0...17.0
        case .solidCircles:
            return 24.0...32.0
        }
    }

    private func dotFallbackTravelDurationRange() -> ClosedRange<Double> {
        switch dotRenderStyle {
        case .dotGrid:
            return 12.0...16.0
        case .solidCircles:
            return 23.0...29.0
        }
    }

    private func dotIdleDelayRange() -> ClosedRange<Double> {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.10...0.45
        case .solidCircles:
            return 0.18...0.65
        }
    }

    private func dotFallbackIdleDelayRange() -> ClosedRange<Double> {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.10...0.30
        case .solidCircles:
            return 0.16...0.48
        }
    }

    private func dotLeadInOverlapRange() -> ClosedRange<Double> {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.55...0.75
        case .solidCircles:
            return 0.72...0.84
        }
    }

    private func dotFallbackLeadInOverlapRange() -> ClosedRange<Double> {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.55...0.70
        case .solidCircles:
            return 0.72...0.82
        }
    }

    private var initialDotLeadInOverlap: Double {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.88
        case .solidCircles:
            return 0.82
        }
    }

    private var dotLongDurationThreshold: Double {
        switch dotRenderStyle {
        case .dotGrid:
            return 16.0
        case .solidCircles:
            return 29.0
        }
    }

    private var dotLeadInMinimum: Double {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.50
        case .solidCircles:
            return 0.68
        }
    }

    private var dotLongDurationLeadInAdjustment: Double {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.05
        case .solidCircles:
            return 0.03
        }
    }

    private var dotScaleRampInEnd: Double {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.25
        case .solidCircles:
            return 0.34
        }
    }

    private var dotScaleRampOutStart: Double {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.80
        case .solidCircles:
            return 0.72
        }
    }

    private var dotMinimumScale: CGFloat {
        switch dotRenderStyle {
        case .dotGrid:
            return 0.60
        case .solidCircles:
            return 0.86
        }
    }

}

private struct BKSeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xD1B5_4A32_9C7E_44F1 : seed
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

    mutating func next(in range: Range<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double((1 << 53) - 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let low = range.lowerBound
        let high = range.upperBound
        guard high >= low else { return low }
        let span = high - low + 1
        return low + Int(nextUInt64() % UInt64(span))
    }

    mutating func nextBool() -> Bool {
        (nextUInt64() & 1) == 0
    }
}

extension Array {
    fileprivate mutating func shuffle(using generator: inout BKSeededRandom) {
        guard count > 1 else { return }
        for index in indices.dropLast() {
            let remaining = count - index
            let offset = Int(generator.next(in: 0..<Double(remaining)))
            swapAt(index, index + offset)
        }
    }
}
