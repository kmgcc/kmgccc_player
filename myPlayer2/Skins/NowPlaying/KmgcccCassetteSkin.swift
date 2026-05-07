//
//  KmgcccCassetteSkin.swift
//  myPlayer2
//
//  kmgccc_player - kmgccc Cassette Skin
//

import AppKit
import Combine
import CoreImage
import ImageIO
import QuartzCore
import SwiftUI

struct KmgcccCassetteSkin: NowPlayingSkin {
    let id: String = "kmgccc.cassette"
    let name: String = NSLocalizedString("skin.kmgccc_cassette.name", comment: "")
    let detail: String = NSLocalizedString("skin.kmgccc_cassette.detail", comment: "")
    let systemImage: String = "music.note.list"
    var isFullscreenCompatible: Bool { true }
    var isNowPlayingCompatible: Bool { true }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(CassetteArtwork(context: context).equatable())
    }

    func makeOverlay(context: SkinContext) -> AnyView? {
        AnyView(CassetteOverlay(context: context))
    }

    var settingsView: AnyView? {
        AnyView(KmgcccCassetteNormalSettingsView())
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(KmgcccCassetteFullscreenSettingsView())
    }
}

private enum CassetteLayout {
    static let sizeReserve: CGFloat = 24
    static let ledHeight: CGFloat = 18

    /// Scale-proportional visual gap between cassette bottom and LED meter.
    static func visualLedGap(for size: CGSize) -> CGFloat {
        max(26, size.height * 0.105)
    }

    // MARK: - Fullscreen Fine-tuning Constants
    /// Counteracts the host-level `fullscreenArtworkScale` multiplier applied in
    /// `FullscreenPlayerView.skinArtworkArea` so the cassette maintains the same
    /// visual size as in window mode.
    static let fullscreenScaleAdjustment: CGFloat = 0.88

    struct Metrics {
        let size: CGSize
        let horizontalOffset: CGFloat
        let centeredYOffset: CGFloat
        let visualizerMode: String
    }

    static func metrics(
        for context: SkinContext,
        isFullscreen: Bool,
        normalVisualizerMode: String,
        fullscreenVisualizerMode: String
    ) -> Metrics {
        let scaleAdjustment = isFullscreen ? fullscreenScaleAdjustment : 1.0
        let adjustedContext = isFullscreen ? context.withContentSizeAdjustment(scaleAdjustment) : context
        let size = cassetteSize(for: adjustedContext)
        let visualizerMode = isFullscreen ? fullscreenVisualizerMode : normalVisualizerMode
        let centeredYOffset: CGFloat = visualizerMode == "led" ? 12 : max(22, min(36, size.height * 0.07))
        let horizontalOffset = FullscreenCoverHorizontalOffset.artworkOffsetX(for: context, baseOffset: -6)
        return Metrics(
            size: size,
            horizontalOffset: horizontalOffset,
            centeredYOffset: centeredYOffset,
            visualizerMode: visualizerMode
        )
    }

    static func cassetteSize(for context: SkinContext) -> CGSize {
        let content = context.contentSize
        let availableHeight = max(0, content.height - (sizeReserve + ledHeight))
        let aspect = tapeAspectRatio()

        let maxWidth = min(content.width * 0.72, 520)
        let maxHeight = min(availableHeight * 0.72, 360)

        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }

        width = max(width, 260)
        height = max(height, 160)

        return CGSize(width: width, height: height)
    }

    static func tapeAspectRatio() -> CGFloat {
        CassetteThemeAssetCache.shared.tapeAspectRatio()
    }
}

private struct CassetteThemeImageSet {
    let shell: NSImage
    let gray: NSImage
    let paper: NSImage
    let outline: NSImage
    let mask: NSImage
}

private final class CassetteThemeImageSetBox: NSObject {
    let value: CassetteThemeImageSet

    init(_ value: CassetteThemeImageSet) {
        self.value = value
    }
}

private final class CassetteThemeAssetCache {
    static let shared = CassetteThemeAssetCache()

    private enum Resource: String {
        case light = "cassette_tape_light"
        case dark = "cassette_tape_dark"
        case gray = "cassette_tape_gray"
        case paper = "cassette_tape_paper"
        case outline = "cassette_tape_outline"
        case mask = "cassette_tape_mask"
    }

    private let cache = NSCache<NSString, CassetteThemeImageSetBox>()
    private let lock = NSLock()
    private var resolvedAspectRatio: CGFloat?

    private init() {
        cache.countLimit = 4
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func imageSet(colorScheme: ColorScheme, maxPixel: Int) -> CassetteThemeImageSet? {
        let key = "\(colorScheme == .dark ? "dark" : "light")-\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        guard
            let shell = loadImage(
                resource: colorScheme == .dark ? .dark : .light,
                maxPixel: maxPixel
            ),
            let gray = loadImage(resource: .gray, maxPixel: maxPixel),
            let paper = loadImage(resource: .paper, maxPixel: maxPixel),
            let outline = loadImage(resource: .outline, maxPixel: maxPixel),
            let mask = loadImage(resource: .mask, maxPixel: maxPixel)
        else {
            return nil
        }

        let imageSet = CassetteThemeImageSet(
            shell: shell,
            gray: gray,
            paper: paper,
            outline: outline,
            mask: mask
        )
        cache.setObject(
            CassetteThemeImageSetBox(imageSet),
            forKey: key,
            cost: estimatedCost(for: imageSet)
        )
        return imageSet
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func tapeAspectRatio() -> CGFloat {
        lock.lock()
        if let resolvedAspectRatio {
            lock.unlock()
            return resolvedAspectRatio
        }
        lock.unlock()

        let ratio: CGFloat
        if
            let url = resourceURL(for: .light),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            height > 0
        {
            ratio = width / height
        } else {
            ratio = 3149.0 / 2006.0
        }

        lock.lock()
        resolvedAspectRatio = ratio
        lock.unlock()
        return ratio
    }

    private func loadImage(resource: Resource, maxPixel: Int) -> NSImage? {
        guard let url = resourceURL(for: resource) else { return nil }
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private func resourceURL(for resource: Resource) -> URL? {
        let bundles = [Bundle.main, Bundle(for: CassetteThemeImageSetBox.self)]
        let relativePaths = [
            "CassetteSkin/\(resource.rawValue).png",
            "Resources/CassetteSkin/\(resource.rawValue).png",
            "\(resource.rawValue).png",
        ]

        for bundle in bundles {
            if
                let direct = bundle.url(
                    forResource: resource.rawValue,
                    withExtension: "png",
                    subdirectory: "CassetteSkin"
                )
            {
                return direct
            }
            if let direct = bundle.url(forResource: resource.rawValue, withExtension: "png") {
                return direct
            }
            guard let resourceURL = bundle.resourceURL else { continue }
            for relativePath in relativePaths {
                let candidate = resourceURL.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
    }

    private func estimatedCost(for imageSet: CassetteThemeImageSet) -> Int {
        [imageSet.shell, imageSet.gray, imageSet.paper, imageSet.outline, imageSet.mask].reduce(0) {
            partial, image in
            partial + Self.estimatedCost(for: image)
        }
    }

    private static func estimatedCost(for image: NSImage) -> Int {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let size = image.size
        return max(1, Int(ceil(size.width)) * Int(ceil(size.height)) * 4)
    }
}

private struct CassetteArtwork: View, Equatable {
    let context: SkinContext
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var showKmgLook: Bool = false
    @Environment(\.displayScale) private var displayScale
    @State private var adjustedArtworkImage: NSImage?
    @State private var adjustedArtworkKey: String?
    @State private var renderKey: String = ""
    @State private var adjustedVisible: Bool = false
    @State private var processingTask: Task<Void, Never>?
    @State private var processingGeneration: UInt64 = 0
    @State private var originalArtworkReleaseTask: Task<Void, Never>?
    @State private var keepsOriginalArtworkLayer: Bool = true

    @AppStorage("skin.kmgcccCassette.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "off"

    static func == (lhs: CassetteArtwork, rhs: CassetteArtwork) -> Bool {
        lhs.showKmgLook == rhs.showKmgLook
            && lhs.normalVisualizerMode == rhs.normalVisualizerMode
            && lhs.fullscreenVisualizerMode == rhs.fullscreenVisualizerMode
            && lhs.context.track?.id == rhs.context.track?.id
            && lhs.context.track?.artworkChecksum == rhs.context.track?.artworkChecksum
            && lhs.context.theme.colorScheme == rhs.context.theme.colorScheme
            && lhs.context.playback.isPlaying == rhs.context.playback.isPlaying
            && lhs.context.presentationMode == rhs.context.presentationMode
            && lhs.context.lyricsVisible == rhs.context.lyricsVisible
            && lhs.context.contentBounds.size == rhs.context.contentBounds.size
            && waveformPaletteSignature(for: lhs.context) == waveformPaletteSignature(for: rhs.context)
    }

    var body: some View {
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout
        let metrics = CassetteLayout.metrics(
            for: context,
            isFullscreen: usesFullscreenLayout,
            normalVisualizerMode: normalVisualizerMode,
            fullscreenVisualizerMode: fullscreenVisualizerMode
        )
        let size = metrics.size
        let themeImages = cassetteThemeImages(for: size)
        let horizontalOffset = metrics.horizontalOffset
        let centeredYOffset = metrics.centeredYOffset

        ZStack {
            cassetteThemeImage(themeImages?.shell, fallbackNamed: tapeAssetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            maskedArtwork(size: size, maskImage: themeImages?.mask)

            cassetteThemeImage(themeImages?.gray, fallbackNamed: "tapegray")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            cassetteThemeImage(themeImages?.paper, fallbackNamed: "tapepaper")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .blendMode(.multiply)
                .opacity(0.40)

            cassetteThemeImage(themeImages?.outline, fallbackNamed: "tapeoutline")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .opacity(context.theme.colorScheme == .dark ? 0.20 : 0.80)
        }
        .overlay(alignment: .bottomTrailing) {
            if showKmgLook {
                Image("kmglook")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: kmgLookWidth(for: size))
                    .scaleEffect(1.50)
                    // Let it extend beyond the cassette bounds into the background.
                    .offset(x: 52, y: -7)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        .overlay(HolesOverlay(context: context))
        .overlay(WaveformCapsulesLayer(context: context).zIndex(999))
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: horizontalOffset, y: centeredYOffset)
        .onAppear {
            scheduleAdjustedArtworkProcessing(targetSize: size)
        }
        .onChange(of: context.track?.id) { _, _ in
            scheduleAdjustedArtworkProcessing(targetSize: size)
        }
        .onChange(of: context.track?.artworkChecksum) { _, _ in
            scheduleAdjustedArtworkProcessing(targetSize: size)
        }
        .onChange(of: context.theme.colorScheme) { _, _ in
            scheduleAdjustedArtworkProcessing(targetSize: size)
        }
        .onChange(of: processingBudgetKey(for: size)) { _, _ in
            scheduleAdjustedArtworkProcessing(targetSize: size)
        }
        .onDisappear {
            teardownArtworkState(purgeCaches: true)
        }
    }

    @ViewBuilder
    private func maskedArtwork(size: CGSize, maskImage: NSImage?) -> some View {
        ZStack {
            if keepsOriginalArtworkLayer || !showAdjustedLayer {
                originalArtworkImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(showAdjustedLayer ? 0 : 1)
            }

            if showAdjustedLayer, let adjustedArtworkImage {
                Image(nsImage: adjustedArtworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(adjustedVisible ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: adjustedVisible)
        .frame(width: size.width, height: size.height)
        .scaleEffect(0.90)
        .clipped()
        .mask(
            cassetteThemeImage(maskImage, fallbackNamed: "tapemask")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .luminanceToAlpha()
        )
    }

    private var showAdjustedLayer: Bool {
        adjustedArtworkKey == renderKey && adjustedArtworkImage != nil
    }

    private var originalArtworkImage: Image {
        if let image = context.track?.artworkImage {
            return Image(nsImage: image)
        }
        return Image("seasons")
    }

    private var tapeAssetName: String {
        context.theme.colorScheme == .dark ? "tapedark" : "tape"
    }

    private func kmgLookWidth(for size: CGSize) -> CGFloat {
        let base = size.width * 0.22
        return min(max(60, base), 120)
    }

    private static func waveformPaletteSignature(for context: SkinContext) -> Int {
        var hasher = Hasher()
        for color in context.theme.artworkPalette.prefix(2) {
            append(color: color, to: &hasher)
        }
        append(color: context.theme.artworkAverageColor, to: &hasher)
        return hasher.finalize()
    }

    private static func append(color: NSColor?, to hasher: inout Hasher) {
        guard let resolved = color?.usingColorSpace(.deviceRGB) ?? color else {
            hasher.combine(0)
            return
        }
        hasher.combine(Int(resolved.redComponent * 1_000))
        hasher.combine(Int(resolved.greenComponent * 1_000))
        hasher.combine(Int(resolved.blueComponent * 1_000))
        hasher.combine(Int(resolved.alphaComponent * 1_000))
    }

    private func scheduleAdjustedArtworkProcessing(targetSize: CGSize) {
        processingTask?.cancel()
        originalArtworkReleaseTask?.cancel()
        processingGeneration &+= 1
        let generation = processingGeneration

        guard let track = context.track, let data = track.artworkData else {
            clearAdjustedArtworkState(resetRenderKey: true)
            return
        }

        let lo = 0.08
        let hi = (context.theme.colorScheme == .dark) ? 0.80 : 0.83
        let midAnchor = 0.5
        let seed = UInt64(bitPattern: Int64(track.id.uuidString.hashValue))
        let maxPixel = processingMaxPixel(for: targetSize)
        let key = makeToneKey(
            trackID: track.id,
            scheme: context.theme.colorScheme,
            lo: lo,
            hi: hi,
            mid: midAnchor,
            checksum: track.artworkChecksum,
            maxPixel: maxPixel
        )
        renderKey = key
        if adjustedArtworkKey != key {
            adjustedArtworkKey = nil
            adjustedArtworkImage = nil
        }
        keepsOriginalArtworkLayer = true
        adjustedVisible = false

        processingTask = Task(priority: .utility) {
            defer {
                Task { @MainActor in
                    guard self.processingGeneration == generation else { return }
                    self.processingTask = nil
                }
            }

            if let cached = await CassetteArtworkCache.shared.image(for: key),
                !Task.isCancelled
            {
                await MainActor.run {
                    guard self.processingGeneration == generation, self.renderKey == key else { return }
                    self.adjustedArtworkImage = cached
                    self.adjustedArtworkKey = key
                    withAnimation(.easeInOut(duration: 0.26)) {
                        self.adjustedVisible = true
                    }
                    self.scheduleOriginalArtworkLayerRelease(generation: generation, key: key)
                }
                return
            }

            let result = await CassetteArtworkProcessor.shared.process(
                data: data,
                lo: lo,
                hi: hi,
                midAnchor: midAnchor,
                seed: seed,
                maxPixel: maxPixel
            )

            guard !Task.isCancelled, let result else {
                return
            }

            await MainActor.run {
                guard self.processingGeneration == generation, self.renderKey == key else { return }
                let image = NSImage(
                    cgImage: result.image,
                    size: NSSize(width: result.image.width, height: result.image.height)
                )
                Task {
                    await CassetteArtworkCache.shared.setImage(image, for: key)
                }
                self.adjustedArtworkImage = image
                self.adjustedArtworkKey = key
                withAnimation(.easeInOut(duration: 0.26)) {
                    self.adjustedVisible = true
                }
                self.scheduleOriginalArtworkLayerRelease(generation: generation, key: key)
            }
        }
    }

    private func makeToneKey(
        trackID: UUID,
        scheme: ColorScheme,
        lo: Double,
        hi: Double,
        mid: Double,
        checksum: UInt64,
        maxPixel: Int
    ) -> String {
        "\(trackID.uuidString)-\(scheme == .dark ? "dark" : "light")-\(String(format: "%.3f", lo))-\(String(format: "%.3f", hi))-\(String(format: "%.3f", mid))-\(checksum)-px:\(maxPixel)"
    }

    private func processingBudgetKey(for size: CGSize) -> Int {
        processingMaxPixel(for: size)
    }

    private func processingMaxPixel(for size: CGSize) -> Int {
        let resolvedScale = max(1.0, displayScale)
        let displayedWidth = size.width * 0.90
        let displayedHeight = size.height * 0.90
        let longestSide = max(displayedWidth, displayedHeight)
        let overscan = max(1.15, min(1.35, displayedWidth / max(1, displayedHeight)))
        let target = Int(ceil(longestSide * resolvedScale * overscan))
        return min(1_600, max(640, target))
    }

    private func themeMaxPixel(for size: CGSize) -> Int {
        let resolvedScale = max(1.0, displayScale)
        let longestSide = max(size.width, size.height)
        let target = Int(ceil(longestSide * resolvedScale * 1.18))
        return min(1_100, max(640, target))
    }

    private func cassetteThemeImages(for size: CGSize) -> CassetteThemeImageSet? {
        CassetteThemeAssetCache.shared.imageSet(
            colorScheme: context.theme.colorScheme,
            maxPixel: themeMaxPixel(for: size)
        )
    }

    private func cassetteThemeImage(_ image: NSImage?, fallbackNamed name: String) -> Image {
        if let image {
            return Image(nsImage: image)
        }
        return Image(name)
    }

    private func clearAdjustedArtworkState(resetRenderKey: Bool) {
        originalArtworkReleaseTask?.cancel()
        originalArtworkReleaseTask = nil
        if resetRenderKey {
            renderKey = ""
        }
        adjustedArtworkKey = nil
        adjustedArtworkImage = nil
        adjustedVisible = false
        keepsOriginalArtworkLayer = true
    }

    private func teardownArtworkState(purgeCaches: Bool) {
        processingGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        originalArtworkReleaseTask?.cancel()
        originalArtworkReleaseTask = nil
        clearAdjustedArtworkState(resetRenderKey: true)

        guard purgeCaches else { return }
        CassetteThemeAssetCache.shared.removeAll()
        Task {
            await CassetteArtworkCache.shared.removeAll()
        }
    }

    private func scheduleOriginalArtworkLayerRelease(generation: UInt64, key: String) {
        originalArtworkReleaseTask?.cancel()
        originalArtworkReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            guard processingGeneration == generation else { return }
            guard renderKey == key else { return }
            guard adjustedVisible, showAdjustedLayer else { return }
            keepsOriginalArtworkLayer = false
            originalArtworkReleaseTask = nil
        }
    }
}

private struct CassetteLumaStats: Sendable {
    let low: Double
    let high: Double
    let mean: Double
}

actor CassetteArtworkCache {
    static let shared = CassetteArtworkCache()

    private var storage: [String: NSImage] = [:]
    private var keys: [String] = []
    private var costs: [String: Int] = [:]
    private var totalBytes = 0
    private let maxCount = 48
    private let maxTotalBytes = 24 * 1024 * 1024

    func image(for key: String) -> NSImage? {
        storage[key]
    }

    func setImage(_ image: NSImage, for key: String) {
        if storage[key] == nil {
            keys.append(key)
        }
        if let previousCost = costs[key] {
            totalBytes -= previousCost
        }
        storage[key] = image
        let cost = Self.estimatedCost(for: image)
        costs[key] = cost
        totalBytes += cost
        while keys.count > maxCount || totalBytes > maxTotalBytes {
            let oldest = keys.removeFirst()
            storage.removeValue(forKey: oldest)
            if let removedCost = costs.removeValue(forKey: oldest) {
                totalBytes -= removedCost
            }
        }
    }

    func removeAll() {
        storage.removeAll()
        keys.removeAll()
        costs.removeAll()
        totalBytes = 0
    }

    private static func estimatedCost(for image: NSImage) -> Int {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let size = image.size
        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        return width * height * 4
    }
}

private actor CassetteArtworkProcessor {
    static let shared = CassetteArtworkProcessor()

    func process(
        data: Data,
        lo: Double,
        hi: Double,
        midAnchor: Double,
        seed: UInt64,
        maxPixel: Int
    ) -> (image: CGImage, before: CassetteLumaStats, after: CassetteLumaStats)? {
        guard !Task.isCancelled else { return nil }
        let result = CassetteArtworkToneMapper.process(
            data: data,
            lo: lo,
            hi: hi,
            midAnchor: midAnchor,
            seed: seed,
            maxPixel: maxPixel
        )
        guard !Task.isCancelled else { return nil }
        return result
    }
}

private enum CassetteArtworkToneMapper {
    nonisolated static func process(
        data: Data,
        lo: Double,
        hi: Double,
        midAnchor: Double,
        seed: UInt64,
        maxPixel: Int
    ) -> (image: CGImage, before: CassetteLumaStats, after: CassetteLumaStats)? {
        return autoreleasepool {
            let ciContext = CIContext(options: [.cacheIntermediates: false])
            guard let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
            guard let input = downsampledInputImage(data: data, maxPixel: maxPixel), !input.extent.isEmpty else { return nil }

            let linearInput = input.applyingFilter("CISRGBToneCurveToLinear")
            guard
                let before = sampledLumaStats(
                    from: linearInput, seed: seed, ciContext: ciContext, linearSpace: linearSpace)
            else { return nil }

            let exposureEV: Double = before.high > hi ? (log2(hi / before.high) * 0.85) : 0
            let exposedLinear =
                exposureEV < 0
                ? linearInput.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposureEV])
                : linearInput

            let toeLift: Double = {
                guard before.low < lo else { return 0 }
                let deficit = lo - before.low
                return min(0.05, max(0.02, deficit * 0.5))
            }()
            let shoulderDrop: Double = {
                let pressure = max(0.0, before.high - hi) / max(1e-4, 1.0 - hi)
                guard pressure > 0 else { return 0 }
                return min(0.08, max(0.03, pressure * 0.08))
            }()

            let point0 = CIVector(x: 0.0, y: 0.0)
            let point1 = CIVector(x: 0.25, y: CGFloat(min(0.30, 0.25 + toeLift)))
            let point2 = CIVector(x: 0.50, y: CGFloat(midAnchor))
            let point3 = CIVector(x: 0.75, y: CGFloat(max(0.62, 0.75 - shoulderDrop)))
            let point4 = CIVector(x: 1.00, y: 1.00)

            let tonedLinear = exposedLinear.applyingFilter(
                "CIToneCurve",
                parameters: [
                    "inputPoint0": point0,
                    "inputPoint1": point1,
                    "inputPoint2": point2,
                    "inputPoint3": point3,
                    "inputPoint4": point4,
                ]
            )

            let ditherAmount = CGFloat(1.0 / 255.0)
            guard let noiseSource = CIFilter(name: "CIRandomGenerator")?.outputImage else {
                return nil
            }
            let noise =
                noiseSource
                .cropped(to: tonedLinear.extent)
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: 0.3333, y: 0.3333, z: 0.3333, w: 0),
                        "inputGVector": CIVector(x: 0.3333, y: 0.3333, z: 0.3333, w: 0),
                        "inputBVector": CIVector(x: 0.3333, y: 0.3333, z: 0.3333, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0),
                    ]
                )
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: ditherAmount, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: ditherAmount, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: ditherAmount, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    ]
                )

            let ditheredLinear = noise.applyingFilter(
                "CIAdditionCompositing",
                parameters: ["inputBackgroundImage": tonedLinear]
            )
            .cropped(to: tonedLinear.extent)

            let clampedLinear = ditheredLinear.applyingFilter(
                "CIColorClamp",
                parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(
                        x: CGFloat(hi),
                        y: CGFloat(hi),
                        z: CGFloat(hi),
                        w: 1
                    ),
                ]
            )

            let outputImage = clampedLinear.applyingFilter("CILinearToSRGBToneCurve")
            guard
                let renderedImage = ciContext.createCGImage(outputImage, from: outputImage.extent),
                let after = sampledLumaStats(
                    from: clampedLinear,
                    seed: seed &+ 0xB529_7A4D,
                    ciContext: ciContext,
                    linearSpace: linearSpace
                )
            else { return nil }

            ciContext.clearCaches()

            #if DEBUG
                let overflow = after.high > hi + 1e-4
                let underflow = after.low < lo - 1e-4
                print(
                    String(
                        format:
                            "[CassetteBrightness] before(min=%.4f max=%.4f mean=%.4f) after(min=%.4f max=%.4f mean=%.4f) lo=%.2f hi=%.2f overflow=%@ underflow=%@",
                        before.low, before.high, before.mean,
                        after.low, after.high, after.mean,
                        lo, hi,
                        overflow ? "YES" : "NO",
                        underflow ? "YES" : "NO"
                    )
                )
                assert(after.high <= hi + 1e-4, "Cassette artwork luma overflow")
            #endif

            return (renderedImage, before, after)
        }
    }

    private nonisolated static func downsampledInputImage(data: Data, maxPixel: Int) -> CIImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return CIImage(cgImage: image)
    }

    private nonisolated static func sampledLumaStats(
        from linearImage: CIImage,
        seed: UInt64,
        ciContext: CIContext,
        linearSpace: CGColorSpace
    ) -> CassetteLumaStats? {
        let sampleW = 32
        let sampleH = 32
        let downsampled =
            linearImage
            .transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(sampleW) / linearImage.extent.width,
                    y: CGFloat(sampleH) / linearImage.extent.height
                )
            )
            .cropped(to: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        var bitmap = [Float](repeating: 0, count: sampleW * sampleH * 4)
        ciContext.render(
            downsampled,
            toBitmap: &bitmap,
            rowBytes: sampleW * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: sampleW, height: sampleH),
            format: .RGBAf,
            colorSpace: linearSpace
        )

        let gridX = 24
        let gridY = 24
        let cellW = Double(sampleW) / Double(gridX)
        let cellH = Double(sampleH) / Double(gridY)

        var rng = seed &+ 0x9E37_79B9_7F4A_7C15
        var low = 1.0
        var high = 0.0
        var total = 0.0
        var count = 0.0

        for gy in 0..<gridY {
            for gx in 0..<gridX {
                let rx = nextRandom01(&rng)
                let ry = nextRandom01(&rng)
                let x = min(sampleW - 1, Int((Double(gx) + rx) * cellW))
                let y = min(sampleH - 1, Int((Double(gy) + ry) * cellH))
                let i = (y * sampleW + x) * 4
                let r = Double(bitmap[i + 0])
                let g = Double(bitmap[i + 1])
                let b = Double(bitmap[i + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                low = min(low, luma)
                high = max(high, luma)
                total += luma
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return CassetteLumaStats(low: low, high: high, mean: total / count)
    }

    private nonisolated static func nextRandom01(_ state: inout UInt64) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let value = (state >> 11) & ((1 << 53) - 1)
        return Double(value) / Double((1 << 53) - 1)
    }
}

private enum WaveformCapsulesConstants {
    static let cx: CGFloat = 0.501
    static let cy: CGFloat = 0.542
    static let capsuleCount = 9
    static let capsuleWidthRatio: CGFloat = 0.01
    static let spacingRatio: CGFloat = 0.017
    static let maxBarHeightRatio: CGFloat = 0.14
    static let heightBoost: CGFloat = 1.0
    static let darkBrightnessMin: CGFloat = 0.10
    static let darkBrightnessMax: CGFloat = 0.14
    static let lightBrightnessMax: CGFloat = 0.55
}

private struct WaveformCapsulesLayer: View {
    let context: SkinContext

    var body: some View {
        WaveformCapsulesRepresentable(
            isPlaying: context.playback.isPlaying,
            isDark: context.theme.colorScheme == .dark,
            artworkPalette: Array(context.theme.artworkPalette.prefix(2)),
            artworkAccentColor: NSColor(context.theme.artworkAccentColor ?? .white)
        )
        .allowsHitTesting(false)
    }
}

private struct WaveformCapsulesRepresentable: NSViewRepresentable {
    let isPlaying: Bool
    let isDark: Bool
    let artworkPalette: [NSColor]
    let artworkAccentColor: NSColor

    func makeNSView(context: Context) -> WaveformCapsulesHostView {
        let view = WaveformCapsulesHostView()
        view.updatePalette(artworkPalette, accentColor: artworkAccentColor, isDark: isDark)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: WaveformCapsulesHostView, context: Context) {
        nsView.updatePalette(artworkPalette, accentColor: artworkAccentColor, isDark: isDark)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: WaveformCapsulesHostView, coordinator: ()) {
        nsView.stop()
        nsView.teardownViewBacking()
    }
}

@MainActor
private final class WaveformCapsulesHostView: NSView {
    #if DEBUG
        private static var liveInstanceCount = 0
        private static let lifecycleLoggingEnabled =
            ProcessInfo.processInfo.environment["KMGCCC_DEBUG_NOWPLAYING_LIFECYCLE"] == "1"
    #endif

    private let service = AudioVisualizationService.shared
    private let rootLayer = CALayer()
    private var capsuleLayers: [CALayer] = []
    private var consumerID: UUID?

    private var currentWave = Array(
        repeating: Float(0),
        count: WaveformCapsulesConstants.capsuleCount
    )
    private var cachedColors: [CGColor] = []
    private var paletteSignature: Int = 0
    private var lastPlaybackState: Bool?
    private var lastLayoutSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ensureViewLayerIfNeeded()
        logLifecycle("init")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            logLifecycle("deinit")
        }
    }

    override func layout() {
        super.layout()
        ensureViewLayerIfNeeded()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        layoutCapsules()
    }

    func start() {
        guard consumerID == nil else { return }
        ensureViewLayerIfNeeded()
        service.start()
        consumerID = service.addConsumer { [weak self] wave in
            self?.applyWave(wave)
        }
    }

    func stop() {
        if let consumerID {
            service.removeConsumer(consumerID)
            self.consumerID = nil
        }
        service.stop()
        currentWave = Array(repeating: 0, count: WaveformCapsulesConstants.capsuleCount)
        teardownViewBacking()
    }

    func setPlayback(isPlaying: Bool) {
        guard lastPlaybackState != isPlaying else { return }
        lastPlaybackState = isPlaying
        service.updatePlaybackState(isPlaying: isPlaying)
    }

    func updatePalette(_ palette: [NSColor], accentColor: NSColor, isDark: Bool) {
        let signature = Self.paletteSignature(
            palette: palette,
            accentColor: accentColor,
            isDark: isDark
        )
        guard signature != paletteSignature else { return }

        paletteSignature = signature
        cachedColors = Self.makeCapsuleColors(
            palette: palette,
            accentColor: accentColor,
            isDark: isDark
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in capsuleLayers.enumerated() where index < cachedColors.count {
            layer.backgroundColor = cachedColors[index]
        }
        CATransaction.commit()
    }

    private func setupCapsuleLayers() {
        guard capsuleLayers.isEmpty else { return }
        capsuleLayers = (0..<WaveformCapsulesConstants.capsuleCount).map { _ in
            let layer = CALayer()
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "frame": NSNull(),
                "backgroundColor": NSNull(),
                "cornerRadius": NSNull(),
            ]
            rootLayer.addSublayer(layer)
            return layer
        }
    }

    func teardownViewBacking() {
        lastLayoutSize = .zero
        paletteSignature = 0
        cachedColors.removeAll(keepingCapacity: false)
        layer?.removeAllAnimations()
        rootLayer.removeAllAnimations()
        rootLayer.sublayers?.forEach { sublayer in
            sublayer.removeAllAnimations()
            sublayer.mask = nil
            sublayer.contents = nil
            sublayer.removeFromSuperlayer()
        }
        rootLayer.sublayers = nil
        rootLayer.contents = nil
        rootLayer.removeFromSuperlayer()
        capsuleLayers.removeAll(keepingCapacity: false)
        layer?.mask = nil
        layer?.contents = nil
        layer?.sublayers = nil
        layer = nil
        wantsLayer = false
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
                "[WaveformCapsulesHostView] \(event) live=\(Self.liveInstanceCount)",
                category: .perf
            )
        #endif
    }

    private func ensureViewLayerIfNeeded() {
        if !wantsLayer {
            wantsLayer = true
        }
        if layer == nil {
            let hostLayer = CALayer()
            hostLayer.masksToBounds = false
            layer = hostLayer
        }
        if rootLayer.superlayer == nil {
            rootLayer.masksToBounds = false
            layer?.addSublayer(rootLayer)
        }
        setupCapsuleLayers()
    }

    private func applyWave(_ wave: [Float]) {
        var normalized = Array(repeating: Float(0), count: WaveformCapsulesConstants.capsuleCount)
        for index in 0..<WaveformCapsulesConstants.capsuleCount {
            if index < wave.count {
                normalized[index] = min(1, max(0, wave[index]))
            }
        }

        let maxDelta = zip(currentWave, normalized).reduce(Float.zero) { partial, pair in
            max(partial, abs(pair.0 - pair.1))
        }
        guard maxDelta >= 0.002 else { return }

        currentWave = normalized
        layoutCapsules()
    }

    private func layoutCapsules() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let width = bounds.width
        let height = bounds.height
        let barWidth = width * WaveformCapsulesConstants.capsuleWidthRatio
        let minHeight = barWidth
        let maxBarHeight = height * WaveformCapsulesConstants.maxBarHeightRatio
        let spacing = width * WaveformCapsulesConstants.spacingRatio
        let totalWidth =
            (CGFloat(WaveformCapsulesConstants.capsuleCount) * barWidth)
            + (CGFloat(WaveformCapsulesConstants.capsuleCount - 1) * spacing)
        let originX = (width * WaveformCapsulesConstants.cx) - (totalWidth * 0.5)
        let centerY = height * (1.0 - WaveformCapsulesConstants.cy)

        rootLayer.frame = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<WaveformCapsulesConstants.capsuleCount {
            let value = CGFloat(currentWave[index]) * WaveformCapsulesConstants.heightBoost
            let dynamicHeight = minHeight + (maxBarHeight - minHeight) * min(1, max(0, value))
            let x = originX + CGFloat(index) * (barWidth + spacing)
            let y = centerY - (dynamicHeight * 0.5)

            let layer = capsuleLayers[index]
            layer.frame = CGRect(x: x, y: y, width: barWidth, height: dynamicHeight)
            layer.cornerRadius = barWidth * 0.5
        }
        CATransaction.commit()
    }

    private static func paletteSignature(palette: [NSColor], accentColor: NSColor, isDark: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(isDark)
        for color in palette.prefix(2) {
            append(color: color, to: &hasher)
        }
        append(color: accentColor, to: &hasher)
        return hasher.finalize()
    }

    private static func append(color: NSColor, to hasher: inout Hasher) {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        hasher.combine(Int(resolved.redComponent * 1_000))
        hasher.combine(Int(resolved.greenComponent * 1_000))
        hasher.combine(Int(resolved.blueComponent * 1_000))
        hasher.combine(Int(resolved.alphaComponent * 1_000))
    }

    private static func makeCapsuleColors(
        palette: [NSColor],
        accentColor: NSColor,
        isDark: Bool
    ) -> [CGColor] {
        let colors: [NSColor]
        if palette.count >= 2 {
            colors = Array(palette.prefix(2))
        } else {
            colors = [accentColor, accentColor.withAlphaComponent(0.7)]
        }

        let leftBase = colors[0]
        let rightBase = colors[min(1, colors.count - 1)]
        let total = max(1, WaveformCapsulesConstants.capsuleCount - 1)

        return (0..<WaveformCapsulesConstants.capsuleCount).map { index in
            let t = CGFloat(index) / CGFloat(total)
            return makeInterpolatedColor(
                leftBase: leftBase,
                rightBase: rightBase,
                t: t,
                isDark: isDark
            ).cgColor
        }
    }

    private static func makeInterpolatedColor(
        leftBase: NSColor,
        rightBase: NSColor,
        t: CGFloat,
        isDark: Bool
    ) -> NSColor {
        guard
            let c1 = leftBase.usingColorSpace(.deviceRGB),
            let c2 = rightBase.usingColorSpace(.deviceRGB)
        else {
            return leftBase
        }

        let red = c1.redComponent + (c2.redComponent - c1.redComponent) * t
        let green = c1.greenComponent + (c2.greenComponent - c1.greenComponent) * t
        let blue = c1.blueComponent + (c2.blueComponent - c1.blueComponent) * t
        let interpolated = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        interpolated.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let targetBrightness: CGFloat
        let targetAlpha: CGFloat

        if isDark {
            targetBrightness = max(
                WaveformCapsulesConstants.darkBrightnessMin,
                min(WaveformCapsulesConstants.darkBrightnessMax, brightness * 0.4)
            )
            targetAlpha = 0.8
            saturation *= 0.9
        } else {
            targetBrightness = min(
                max(0.1, brightness * 0.7),
                WaveformCapsulesConstants.lightBrightnessMax
            )
            targetAlpha = 0.85
        }

        return NSColor(
            hue: hue,
            saturation: saturation,
            brightness: targetBrightness,
            alpha: targetAlpha
        )
    }

}

// MARK: - Physics Engine

@MainActor
private class HolePhysics: ObservableObject {
    @Published var angle: Double = 0
    var omega: Double = 0  // deg/s

    // Physics constants
    private let targetSpeed: Double = 45.0
    private let startTau: Double = 0.25  // Seconds to reach ~63% speed
    private let stopTau: Double = 0.45  // Seconds to slow down (high inertia)

    private var lastTime: TimeInterval = 0

    func tick(at date: Date, isPlaying: Bool) {
        let now = date.timeIntervalSinceReferenceDate

        // First tick init
        if lastTime == 0 {
            lastTime = now
            return
        }

        // Calculate clamped delta time
        var dt = now - lastTime
        lastTime = now
        if dt > 0.1 { dt = 0.016 }  // Prevent jumps on resume

        // Determine targets
        let targetOmega = isPlaying ? targetSpeed : 0.0
        let tau = isPlaying ? startTau : stopTau

        // Apply damping (Spring/Friction simulation)
        // omega_new = target + (omega_old - target) * e^(-dt/tau)
        // derived from: d(omega)/dt = (target - omega) / tau
        let decay = exp(-dt / tau)
        omega = targetOmega + (omega - targetOmega) * decay

        // Integrate angle
        angle += omega * dt

        // Wrap to prevent float drift over long periods
        if angle > 36000 { angle -= 36000 }
    }
}

// MARK: - Rotating Layer

private struct HolesOverlay: View {
    let context: SkinContext

    // Persist physics state across layout updates
    @StateObject private var physics = HolePhysics()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let minDim = min(w, h)
            let holeSize = minDim * 0.16

            // Resolve assets once
            let imgName = context.theme.colorScheme == .dark ? "darkhole" : "lighthole"

            // Determine if we can sleep the timeline loop
            // Sleep if: Not playing AND essentially stopped (omega near 0)
            let isPlaying = context.playback.isPlaying
            let isStationary = !isPlaying && abs(physics.omega) < 0.1
            // The original instruction had `AnyLayout` for schedule, which is incorrect.
            // Using `TimelineView(.animation(minimumInterval:paused:))` directly.

            TimelineView(
                .animation(minimumInterval: isStationary ? 1.0 : 1.0 / 60.0, paused: isStationary)
            ) { timeline in
                Canvas { ctx, size in
                    // 1. Resolve image
                    // Note: In a real app, optimize by resolving Image once outside if possible,
                    // but Canvas requires context-bound resolution.
                    // System caches this efficiently.
                    guard let resolved = ctx.resolveSymbol(id: "hole") else { return }

                    // 2. Draw Left Hole
                    ctx.drawLayer { lctx in
                        lctx.translateBy(x: w * 0.2960, y: h * 0.5424)
                        lctx.rotate(by: .degrees(physics.angle))
                        lctx.draw(resolved, at: .zero)
                    }

                    // 3. Draw Right Hole
                    ctx.drawLayer { lctx in
                        lctx.translateBy(x: w * 0.7066, y: h * 0.5424)
                        lctx.rotate(by: .degrees(physics.angle))
                        lctx.draw(resolved, at: .zero)
                    }
                } symbols: {
                    // Symbol definition (drawn once, rasterized if grouped)
                    Image(imgName)
                        .resizable()
                        .frame(width: holeSize, height: holeSize)
                        .tag("hole")
                }
                .onChange(of: timeline.date) { _, newDate in
                    physics.tick(at: newDate, isPlaying: isPlaying)
                }
            }
        }
        // Isolate compositing to avoid redrawing parent cassette layers
        .allowsHitTesting(false)
    }
}

private struct CassetteOverlay: View {
    let context: SkinContext
    @AppStorage("skin.kmgcccCassette.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "off"

    var body: some View {
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout
        let metrics = CassetteLayout.metrics(
            for: context,
            isFullscreen: usesFullscreenLayout,
            normalVisualizerMode: normalVisualizerMode,
            fullscreenVisualizerMode: fullscreenVisualizerMode
        )
        let size = metrics.size
        let yOffset = metrics.centeredYOffset + size.height / 2 + CassetteLayout.visualLedGap(for: size)
        let horizontalOffset = metrics.horizontalOffset

        Group {
            if metrics.visualizerMode == "led" {
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: 12,
                    spacing: 8,
                    pillTint: context.theme.artworkAccentColor,
                    isPlaying: context.playback.isPlaying,
                    forceBrightLEDColors: context.theme.artBackgroundIsUltraDark
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(x: horizontalOffset, y: yOffset)
            }
        }
    }
}

private struct KmgcccCassetteNormalSettingsView: View {
    @AppStorage("skin.kmgcccCassette.visualizerMode") private var visualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var showKmgLook: Bool = false
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSwitchRow(title: "LED 电平表", isOn: Binding(
                get: { visualizerMode == "led" },
                set: { isOn in
                    if isOn {
                        visualizerMode = "led"
                        ledMeterProvider.getOrCreate().start()
                    } else if visualizerMode == "led" {
                        visualizerMode = "off"
                        ledMeterProvider.releaseNowPlayingResources()
                    }
                }
            ))

            SettingsSwitchRow(
                title: NSLocalizedString("skin.kmgccc_cassette.show_kmg", comment: ""),
                isOn: $showKmgLook
            )
        }
    }
}

private struct KmgcccCassetteFullscreenSettingsView: View {
    @AppStorage("skin.kmgcccCassette.fullscreen.visualizerMode") private var visualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var showKmgLook: Bool = false
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(title: "LED 电平表", isOn: Binding(
                get: { visualizerMode == "led" },
                set: { isOn in
                    visualizerMode = isOn ? "led" : "off"
                }
            ), titleFont: presentationStyle.rowLabelFont, titleColor: presentationStyle.primaryTextColor)

            SettingsSwitchRow(
                title: NSLocalizedString("skin.kmgccc_cassette.show_kmg", comment: ""),
                isOn: $showKmgLook,
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.primaryTextColor
            )
        }
    }
}
