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
        case light = "tape"
        case dark = "tapedark"
        case gray = "tapegray"
        case paper = "tapepaper"
        case outline = "tapeoutline"
        case mask = "tapemask"
    }

    private let cache = NSCache<NSString, CassetteThemeImageSetBox>()
    private let lock = NSLock()
    private var resolvedAspectRatio: CGFloat?

    private init() {
        cache.countLimit = 4
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func imageSet(
        colorScheme: ColorScheme,
        cassetteTint: CassetteTintPalette,
        maxPixel: Int
    ) -> CassetteThemeImageSet? {
        let tintSignature = colorScheme == .dark ? cassetteTint.signature : 0
        let key = "\(colorScheme == .dark ? "dark" : "light")-\(maxPixel)-tint:\(tintSignature)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        guard
            let shell = loadImage(
                resource: colorScheme == .dark ? .dark : .light,
                maxPixel: maxPixel,
                tint: colorScheme == .dark ? cassetteTint : nil
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
        if let image = loadImage(resource: .light, maxPixel: 4096), image.size.height > 0 {
            ratio = image.size.width / image.size.height
        } else {
            ratio = 3149.0 / 2006.0
        }

        lock.lock()
        resolvedAspectRatio = ratio
        lock.unlock()
        return ratio
    }

    private func loadImage(
        resource: Resource,
        maxPixel: Int,
        tint: CassetteTintPalette? = nil
    ) -> NSImage? {
        guard let image = ArtAssetLoader.shared.xcAssetImage(
            named: resource.rawValue,
            maxPixel: max(1, maxPixel)
        ) else {
            return nil
        }
        guard resource == .dark, let tint else { return image }
        return CassetteAssetToneMapper.colorized(image, tint: tint) ?? image
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

/// Maps only the grayscale value of the encrypted dark cassette art to the
/// semantic night tint. Alpha and the source's luminance structure remain
/// owned by the asset; no other cassette layer passes through this mapper.
private enum CassetteAssetToneMapper {
    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    static func colorized(_ image: NSImage, tint: CassetteTintPalette) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rendered = colorized(source, tint: tint) else {
            return nil
        }
        return NSImage(
            cgImage: rendered,
            size: NSSize(width: rendered.width, height: rendered.height)
        )
    }

    private static func colorized(_ image: CGImage, tint: CassetteTintPalette) -> CGImage? {
        autoreleasepool {
            guard let gradient = makeColorMapImage(colors: tint.colors) else { return nil }
            let input = CIImage(cgImage: image)
            let grayscale = input.applyingFilter(
                "CIColorControls",
                parameters: [kCIInputSaturationKey: 0.0]
            )
            let gammaLifted = grayscale.applyingFilter(
                "CIGammaAdjust",
                parameters: [
                    "inputPower": ColorSystemTokens.Cassette.lowLuminanceGamma,
                ]
            )
            let mapped = gammaLifted.applyingFilter(
                "CIColorMap",
                parameters: ["inputGradientImage": gradient]
            )
            let context = CIContext(options: [.cacheIntermediates: false])
            let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)
                ?? CGColorSpaceCreateDeviceRGB()
            let rendered = context.createCGImage(
                mapped,
                from: input.extent,
                format: .RGBA8,
                colorSpace: outputSpace
            )
            context.clearCaches()
            return rendered
        }
    }

    private static func makeColorMapImage(colors: [NSColor]) -> CIImage? {
        let components = colors.compactMap { color -> RGBA? in
            guard let resolved = ColorRenderingAdapter.resolve(color, target: .displayP3) else {
                return nil
            }
            return RGBA(
                red: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.alpha)
            )
        }
        guard !components.isEmpty else { return nil }

        let width = 256
        var data = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            let (left, right, localT): (RGBA, RGBA, CGFloat)
            if components.count == 1 {
                left = components[0]
                right = components[0]
                localT = 0
            } else {
                let position = t * CGFloat(components.count - 1)
                let leftIndex = min(components.count - 2, max(0, Int(floor(position))))
                left = components[leftIndex]
                right = components[leftIndex + 1]
                localT = position - CGFloat(leftIndex)
            }
            let index = x * 4
            data[index] = byte(lerp(left.red, right.red, t: localT))
            data[index + 1] = byte(lerp(left.green, right.green, t: localT))
            data[index + 2] = byte(lerp(left.blue, right.blue, t: localT))
            data[index + 3] = byte(lerp(left.alpha, right.alpha, t: localT))
        }

        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let cgImage = CGImage(
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }

    private static func lerp(_ lhs: CGFloat, _ rhs: CGFloat, t: CGFloat) -> CGFloat {
        let p = max(0, min(1, t))
        return lhs + (rhs - lhs) * p
    }

    private static func byte(_ value: CGFloat) -> UInt8 {
        UInt8((max(0, min(1, value)) * 255).rounded())
    }
}

private struct CassetteArtwork: View, Equatable {
    private struct ArtworkSourceIdentity: Equatable {
        let trackID: UUID?
        let displayedArtworkID: UUID?
        let artworkChecksum: UInt64
        let dataFingerprint: UInt64
    }

    private struct ProcessingInputKey: Equatable {
        let source: ArtworkSourceIdentity
        let isDark: Bool
        let maxPixel: Int
    }

    let context: SkinContext
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var showKmgLook: Bool = false
    @Environment(\.displayScale) private var displayScale
    @State private var adjustedArtworkImage: NSImage?
    @State private var adjustedArtworkKey: String?
    @State private var previewArtworkImage: NSImage?
    @State private var previewArtworkKey: String?
    @State private var renderKey: String = ""
    @State private var processingTask: Task<Void, Never>?
    @State private var processingGeneration: UInt64 = 0

    @AppStorage("skin.kmgcccCassette.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "off"

    static func == (lhs: CassetteArtwork, rhs: CassetteArtwork) -> Bool {
        lhs.showKmgLook == rhs.showKmgLook
            && lhs.normalVisualizerMode == rhs.normalVisualizerMode
            && lhs.fullscreenVisualizerMode == rhs.fullscreenVisualizerMode
            && artworkSourceIdentity(for: lhs.context.track)
                == artworkSourceIdentity(for: rhs.context.track)
            && lhs.context.theme.colorScheme == rhs.context.theme.colorScheme
            && lhs.context.playback.isPlaying == rhs.context.playback.isPlaying
            && lhs.context.presentationMode == rhs.context.presentationMode
            && lhs.context.lyricsVisible == rhs.context.lyricsVisible
            && lhs.context.contentBounds.size == rhs.context.contentBounds.size
            && waveformPaletteSignature(for: lhs.context) == waveformPaletteSignature(for: rhs.context)
            && cassetteTintSignature(for: lhs.context) == cassetteTintSignature(for: rhs.context)
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
                ArtAssetImages.image(
                    named: "kmglook",
                    maxPixel: Int(ceil(kmgLookWidth(for: size) * displayScale * 2))
                )
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
        .onChange(of: artworkProcessingInputKey(for: size)) { _, _ in
            scheduleAdjustedArtworkProcessing(targetSize: size)
        }
        .onDisappear {
            teardownArtworkState(purgeCaches: true)
        }
    }

    @ViewBuilder
    private func maskedArtwork(size: CGSize, maskImage: NSImage?) -> some View {
        displayedArtworkImage
            .resizable()
            .aspectRatio(contentMode: .fill)
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

    private var displayedArtworkImage: Image {
        if showAdjustedLayer, let adjustedArtworkImage {
            return Image(nsImage: adjustedArtworkImage)
        }
        if previewArtworkKey == renderKey, let previewArtworkImage {
            return Image(nsImage: previewArtworkImage)
        }
        return originalArtworkImage
    }

    private var originalArtworkImage: Image {
        if let image = context.track?.artworkImage {
            return Image(nsImage: image)
        }
        if let image = ArtAssetLoader.shared.xcAssetImage(named: "seasons", maxPixel: 1_600) {
            return Image(nsImage: image)
        }
        return Image(systemName: "music.note")
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

    private static func cassetteTintSignature(for context: SkinContext) -> Int {
        context.theme.colorScheme == .dark ? context.theme.cassetteTint.signature : 0
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

    private static func artworkSourceIdentity(
        for track: SkinContext.TrackMetadata?
    ) -> ArtworkSourceIdentity {
        ArtworkSourceIdentity(
            trackID: track?.id,
            displayedArtworkID: track.map { $0.displayedArtworkID ?? $0.id },
            artworkChecksum: track?.artworkChecksum ?? 0,
            dataFingerprint: ArtworkDataFingerprint.sampledHash(for: track?.artworkData)
        )
    }

    private func artworkProcessingInputKey(for size: CGSize) -> ProcessingInputKey {
        ProcessingInputKey(
            source: Self.artworkSourceIdentity(for: context.track),
            isDark: context.theme.colorScheme == .dark,
            maxPixel: processingBudgetKey(for: size)
        )
    }

    private func scheduleAdjustedArtworkProcessing(targetSize: CGSize) {
        processingTask?.cancel()
        processingGeneration &+= 1
        let generation = processingGeneration

        guard let track = context.track, let data = track.artworkData, !data.isEmpty else {
            processingTask = nil
            clearAdjustedArtworkState(resetRenderKey: true)
            return
        }

        let lo = 0.08
        let hi = (context.theme.colorScheme == .dark) ? 0.80 : 0.83
        let midAnchor = 0.5
        let seed = UInt64(bitPattern: Int64(track.id.uuidString.hashValue))
        let maxPixel = processingMaxPixel(for: targetSize)
        let dataFingerprint = ArtworkDataFingerprint.sampledHash(for: data)
        let key = makeToneKey(
            trackID: track.id,
            scheme: context.theme.colorScheme,
            lo: lo,
            hi: hi,
            mid: midAnchor,
            checksum: track.artworkChecksum,
            dataFingerprint: dataFingerprint,
            maxPixel: maxPixel
        )
        renderKey = key
        if adjustedArtworkKey != key {
            adjustedArtworkKey = nil
            adjustedArtworkImage = nil
        }
        if previewArtworkKey != key {
            previewArtworkKey = nil
            previewArtworkImage = nil
        }

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
                }
                return
            }

            let preview = await Task.detached(priority: .userInitiated) {
                Self.previewArtworkImage(from: data, maxPixel: min(520, max(280, maxPixel / 2)))
            }.value

            if let preview, !Task.isCancelled {
                await MainActor.run {
                    guard self.processingGeneration == generation, self.renderKey == key else { return }
                    self.previewArtworkImage = preview
                    self.previewArtworkKey = key
                }
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
        dataFingerprint: UInt64,
        maxPixel: Int
    ) -> String {
        "\(trackID.uuidString)-\(scheme == .dark ? "dark" : "light")-\(String(format: "%.3f", lo))-\(String(format: "%.3f", hi))-\(String(format: "%.3f", mid))-\(checksum)-\(dataFingerprint)-px:\(maxPixel)"
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
            cassetteTint: context.theme.cassetteTint,
            maxPixel: themeMaxPixel(for: size)
        )
    }

    private func cassetteThemeImage(_ image: NSImage?, fallbackNamed name: String) -> Image {
        if let image {
            return Image(nsImage: image)
        }
        if let image = ArtAssetLoader.shared.xcAssetImage(named: name, maxPixel: 1_600) {
            let rendered = context.theme.colorScheme == .dark && name == "tapedark"
                ? CassetteAssetToneMapper.colorized(image, tint: context.theme.cassetteTint) ?? image
                : image
            return Image(nsImage: rendered)
        }
        return Image(systemName: "photo")
    }

    private func clearAdjustedArtworkState(resetRenderKey: Bool) {
        if resetRenderKey {
            renderKey = ""
        }
        adjustedArtworkKey = nil
        adjustedArtworkImage = nil
        previewArtworkKey = nil
        previewArtworkImage = nil
    }

    private func teardownArtworkState(purgeCaches: Bool) {
        processingGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        clearAdjustedArtworkState(resetRenderKey: true)

        guard purgeCaches else { return }
        CassetteThemeAssetCache.shared.removeAll()
        Task {
            await CassetteArtworkCache.shared.removeAll()
        }
    }

    private nonisolated static func previewArtworkImage(from data: Data, maxPixel: Int) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              cgImage.width > 1,
              cgImage.height > 1
        else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
    static let darkBrightnessMin: CGFloat = 0.055
    static let darkBrightnessMax: CGFloat = 0.115
    static let darkBrightnessScale: CGFloat = 0.22
    static let darkAlpha: CGFloat = 0.72
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

    func makeNSView(context: Context) -> CapsuleSpectrumHostView {
        let view = CapsuleSpectrumHostView(configuration: makeConfiguration())
        applyColors(to: view)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: CapsuleSpectrumHostView, context: Context) {
        nsView.configure(makeConfiguration())
        applyColors(to: nsView)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: CapsuleSpectrumHostView, coordinator: ()) {
        nsView.stop()
        nsView.teardownBacking()
    }

    private func makeConfiguration() -> CapsuleSpectrumConfiguration {
        CapsuleSpectrumConfiguration(
            capsuleCount: WaveformCapsulesConstants.capsuleCount,
            dynamics: .standard,
            pausedBehavior: .idlePose,
            strokeWidth: 0,
            heightBoost: WaveformCapsulesConstants.heightBoost,
            // The cassette waveform is deliberately short (heightBoost lifts it);
            // keep identity so the dynamic-range compression doesn't shrink it.
            levelShaping: .identity
        ) { bounds, count in
            let barWidth = bounds.width * WaveformCapsulesConstants.capsuleWidthRatio
            let spacing = bounds.width * WaveformCapsulesConstants.spacingRatio
            let totalWidth = CGFloat(count) * barWidth
                + CGFloat(max(0, count - 1)) * spacing
            return CapsuleSpectrumMetrics(
                barWidth: barWidth,
                spacing: spacing,
                minHeight: barWidth,
                maxBarHeight: bounds.height * WaveformCapsulesConstants.maxBarHeightRatio,
                originX: bounds.width * WaveformCapsulesConstants.cx - totalWidth * 0.5,
                centerY: bounds.height * (1.0 - WaveformCapsulesConstants.cy),
                cornerRadius: barWidth * 0.5
            )
        }
    }

    private func applyColors(to view: CapsuleSpectrumHostView) {
        let signature = WaveformCapsulesPalette.signature(
            palette: artworkPalette,
            accentColor: artworkAccentColor,
            isDark: isDark
        )
        view.updateColors(signature: signature) {
            let colors = WaveformCapsulesPalette.colors(
                palette: artworkPalette,
                accentColor: artworkAccentColor,
                isDark: isDark
            )
            return (colors, nil)
        }
    }
}

/// Cassette-specific bar colors: a two-stop interpolation across the artwork's
/// dominant palette, tuned per appearance. Relocated out of the former host
/// view so the shared CapsuleSpectrumHostView can drive the Cassette bars.
private enum WaveformCapsulesPalette {

    static func signature(palette: [NSColor], accentColor: NSColor, isDark: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(isDark)
        for color in palette.prefix(2) {
            append(color: color, to: &hasher)
        }
        append(color: accentColor, to: &hasher)
        return hasher.finalize()
    }

    static func colors(palette: [NSColor], accentColor: NSColor, isDark: Bool) -> [CGColor] {
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
            let color = makeInterpolatedColor(
                leftBase: leftBase,
                rightBase: rightBase,
                t: t,
                isDark: isDark
            )
            return ColorRenderingAdapter.makeCGColor(color)
        }
    }

    private static func append(color: NSColor, to hasher: inout Hasher) {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        hasher.combine(Int(resolved.redComponent * 1_000))
        hasher.combine(Int(resolved.greenComponent * 1_000))
        hasher.combine(Int(resolved.blueComponent * 1_000))
        hasher.combine(Int(resolved.alphaComponent * 1_000))
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

        // Allowed legacy HSB residual: local graphic/rendering transform for capsule waveform.
        // Does not participate in semantic color decisions.
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
                min(
                    WaveformCapsulesConstants.darkBrightnessMax,
                    brightness * WaveformCapsulesConstants.darkBrightnessScale
                )
            )
            targetAlpha = WaveformCapsulesConstants.darkAlpha
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

// MARK: - Rotating Layer

private struct HolesOverlay: View {
    let context: SkinContext
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        CassetteHoleRotationRepresentable(
            imageName: context.theme.colorScheme == .dark ? "darkhole" : "lighthole",
            tint: context.theme.cassetteTint,
            isPlaying: context.playback.isPlaying,
            displayScale: displayScale
        )
        .allowsHitTesting(false)
    }
}

private struct CassetteHoleRotationRepresentable: NSViewRepresentable {
    let imageName: String
    let tint: CassetteTintPalette
    let isPlaying: Bool
    let displayScale: CGFloat

    func makeNSView(context: Context) -> CassetteHoleRotationHostView {
        let view = CassetteHoleRotationHostView()
        view.configure(
            imageName: imageName,
            tint: tint,
            isPlaying: isPlaying,
            displayScale: displayScale
        )
        return view
    }

    func updateNSView(_ nsView: CassetteHoleRotationHostView, context: Context) {
        nsView.configure(
            imageName: imageName,
            tint: tint,
            isPlaying: isPlaying,
            displayScale: displayScale
        )
    }

    static func dismantleNSView(_ nsView: CassetteHoleRotationHostView, coordinator: ()) {
        nsView.prepareForDismissal()
    }
}

/// Tiny AppKit bridge for server-side reel rotation. SwiftUI owns image/theme
/// and playback state; Core Animation owns interpolation between those changes.
@MainActor
private final class CassetteHoleRotationHostView: NSView {
    private enum Constants {
        // Canvas used a top-left coordinate space, where positive angles rotate
        // clockwise. CALayer is bottom-left, so use the negative equivalent.
        static let targetAngularVelocity = -CGFloat.pi / 4  // 45 degrees / second
        static let startTau: TimeInterval = 0.25
        static let stopTau: TimeInterval = 0.45
        static let accelerationDuration: TimeInterval = 1.1
        static let decelerationDuration: TimeInterval = 2.75
        static let fullRotationDuration: TimeInterval = 8.0
        static let sampleCount = 28
    }

    private let rootLayer = CALayer()
    private let leftHoleLayer = CALayer()
    private let rightHoleLayer = CALayer()
    private var imageName = ""
    private var tint: CassetteTintPalette?
    private var tintSignature = 0
    private var loadedMaxPixel = 0
    private var displayScale: CGFloat = 2
    private var requestedPlaying = false
    private var animationGeneration: UInt64 = 0
    private var handoffWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = rootLayer
        rootLayer.masksToBounds = false
        configureLayer(leftHoleLayer)
        configureLayer(rightHoleLayer)
        rootLayer.addSublayer(leftHoleLayer)
        rootLayer.addSublayer(rightHoleLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = bounds
        let holeSide = min(bounds.width, bounds.height) * 0.16
        let holeBounds = CGRect(x: 0, y: 0, width: holeSide, height: holeSide)
        leftHoleLayer.bounds = holeBounds
        rightHoleLayer.bounds = holeBounds
        let canvasY = bounds.height * (1 - 0.5424)
        leftHoleLayer.position = CGPoint(x: bounds.width * 0.2960, y: canvasY)
        rightHoleLayer.position = CGPoint(x: bounds.width * 0.7066, y: canvasY)
        CATransaction.commit()
        updateImageIfNeeded(holeSide: holeSide)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAtPresentationAngle()
        } else if requestedPlaying {
            beginAcceleration()
        }
    }

    func configure(
        imageName: String,
        tint: CassetteTintPalette,
        isPlaying: Bool,
        displayScale: CGFloat
    ) {
        let imageChanged = self.imageName != imageName
        let tintChanged = tintSignature != tint.signature
        let scaleChanged = abs(self.displayScale - displayScale) > 0.01
        self.imageName = imageName
        self.tint = tint
        self.tintSignature = tint.signature
        self.displayScale = max(1, displayScale)
        if imageChanged || tintChanged || scaleChanged {
            loadedMaxPixel = 0
            needsLayout = true
        }

        guard requestedPlaying != isPlaying else { return }
        requestedPlaying = isPlaying
        if isPlaying, window != nil {
            beginAcceleration()
        } else {
            beginDeceleration()
        }
    }

    func prepareForDismissal() {
        requestedPlaying = false
        handoffWorkItem?.cancel()
        handoffWorkItem = nil
        animationGeneration &+= 1
        leftHoleLayer.removeAllAnimations()
        rightHoleLayer.removeAllAnimations()
    }

    private func configureLayer(_ layer: CALayer) {
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "transform": NSNull(),
        ]
    }

    private func updateImageIfNeeded(holeSide: CGFloat) {
        let maxPixel = max(1, Int(ceil(holeSide * 2)))
        guard maxPixel != loadedMaxPixel else { return }
        loadedMaxPixel = maxPixel
        let sourceImage = ArtAssetLoader.shared.xcAssetImage(
            named: imageName,
            maxPixel: maxPixel,
            fallbackToProgrammaticArt: true
        )
        let image: NSImage?
        if imageName == "darkhole", let sourceImage, let tint {
            image = CassetteAssetToneMapper.colorized(sourceImage, tint: tint) ?? sourceImage
        } else {
            image = sourceImage
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftHoleLayer.contents = image
        rightHoleLayer.contents = image
        leftHoleLayer.contentsScale = displayScale
        rightHoleLayer.contentsScale = displayScale
        CATransaction.commit()
    }

    private func beginAcceleration() {
        animationGeneration &+= 1
        let generation = animationGeneration
        handoffWorkItem?.cancel()
        let startAngle = stopAtPresentationAngle()
        let values = sampledAngles(
            startAngle: startAngle,
            duration: Constants.accelerationDuration
        ) { time in
            Constants.targetAngularVelocity
                * CGFloat(time - Constants.startTau * (1 - exp(-time / Constants.startTau)))
        }
        let finalAngle = values.last ?? startAngle
        addKeyframeAnimation(values: values, duration: Constants.accelerationDuration, finalAngle: finalAngle)

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.animationGeneration == generation,
                  self.requestedPlaying,
                  self.window != nil else { return }
            self.beginContinuousRotation(from: finalAngle)
        }
        handoffWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.accelerationDuration, execute: work)
    }

    private func beginDeceleration() {
        animationGeneration &+= 1
        handoffWorkItem?.cancel()
        handoffWorkItem = nil
        let startAngle = stopAtPresentationAngle()
        guard window != nil else { return }
        let values = sampledAngles(
            startAngle: startAngle,
            duration: Constants.decelerationDuration
        ) { time in
            Constants.targetAngularVelocity * CGFloat(Constants.stopTau * (1 - exp(-time / Constants.stopTau)))
        }
        addKeyframeAnimation(
            values: values,
            duration: Constants.decelerationDuration,
            finalAngle: values.last ?? startAngle
        )
    }

    private func beginContinuousRotation(from startAngle: CGFloat) {
        handoffWorkItem = nil
        setModelAngle(startAngle)
        for layer in [leftHoleLayer, rightHoleLayer] {
            layer.removeAnimation(forKey: "cassetteReelTransition")
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = startAngle
            let revolution = Constants.targetAngularVelocity < 0
                ? -2 * CGFloat.pi
                : 2 * CGFloat.pi
            animation.toValue = startAngle + revolution
            animation.duration = Constants.fullRotationDuration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "cassetteReelContinuous")
        }
    }

    @discardableResult
    private func stopAtPresentationAngle() -> CGFloat {
        let angle = presentationAngle(of: leftHoleLayer)
        leftHoleLayer.removeAllAnimations()
        rightHoleLayer.removeAllAnimations()
        setModelAngle(angle)
        return angle
    }

    private func addKeyframeAnimation(values: [CGFloat], duration: TimeInterval, finalAngle: CGFloat) {
        setModelAngle(finalAngle)
        for layer in [leftHoleLayer, rightHoleLayer] {
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            animation.values = values
            animation.duration = duration
            animation.calculationMode = .linear
            animation.isRemovedOnCompletion = true
            layer.add(animation, forKey: "cassetteReelTransition")
        }
    }

    private func sampledAngles(
        startAngle: CGFloat,
        duration: TimeInterval,
        offset: (TimeInterval) -> CGFloat
    ) -> [CGFloat] {
        (0...Constants.sampleCount).map { index in
            let time = duration * TimeInterval(index) / TimeInterval(Constants.sampleCount)
            return startAngle + offset(time)
        }
    }

    private func presentationAngle(of layer: CALayer) -> CGFloat {
        if let number = layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let number = layer.value(forKeyPath: "transform.rotation.z") as? NSNumber {
            return CGFloat(truncating: number)
        }
        return 0
    }

    private func setModelAngle(_ angle: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftHoleLayer.setValue(angle, forKeyPath: "transform.rotation.z")
        rightHoleLayer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
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
                LiveLedMeterView(
                    dotSize: 12,
                    spacing: 8,
                    pillTint: context.theme.artworkAccentColor,
                    isPlaying: context.playback.isPlaying,
                    forceBrightLEDColors: context.theme.artBackgroundIsUltraDark,
                    levelToneVariant: .skinLight
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
    @AppStorage("fullscreenArtBackgroundEnabled") private var fullscreenArtBackgroundEnabled: Bool = true
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(
                title: "启用艺术背景",
                isOn: $fullscreenArtBackgroundEnabled,
                detail: "遇到性能问题时，可以关闭此选项",
                titleFont: presentationStyle.rowLabelFont,
                detailFont: presentationStyle.captionFont,
                titleColor: presentationStyle.primaryTextColor,
                detailColor: presentationStyle.secondaryTextColor
            )

            SettingsSwitchRow(title: "LED 电平表", isOn: Binding(
                get: { visualizerMode == "led" },
                set: { isOn in
                    if isOn {
                        FullscreenPresentationCoordinator.shared.disableMiniPlayerSpectrumForExplicitUserChoice()
                    }
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
