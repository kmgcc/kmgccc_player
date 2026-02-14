//
//  KmgcccCassetteSkin.swift
//  myPlayer2
//
//  kmgccc_player - kmgccc Cassette Skin
//

import AppKit
import Combine
import CoreImage
import SwiftUI

struct KmgcccCassetteSkin: NowPlayingSkin {
    let id: String = "kmgccc.cassette"
    let name: String = NSLocalizedString("skin.kmgccc_cassette.name", comment: "")
    let detail: String = NSLocalizedString("skin.kmgccc_cassette.detail", comment: "")
    let systemImage: String = "music.note.list"

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(CassetteArtwork(context: context))
    }

    func makeOverlay(context: SkinContext) -> AnyView? {
        AnyView(CassetteOverlay(context: context))
    }

    var settingsView: AnyView? {
        AnyView(KmgcccCassetteSettingsView())
    }
}

private enum CassetteLayout {
    static let ledGap: CGFloat = 24
    static let ledHeight: CGFloat = 18

    static func cassetteSize(for context: SkinContext) -> CGSize {
        let content = context.contentSize
        let availableHeight = max(0, content.height - (ledGap + ledHeight))
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
        if let size = NSImage(named: "tape")?.size, size.height > 0 {
            return size.width / size.height
        }
        return 1.6
    }
}

private struct CassetteArtwork: View {
    let context: SkinContext
    @AppStorage("skin.kmgcccCassette.showLEDMeter") private var showLEDMeter: Bool = false
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var showKmgLook: Bool = false
    @State private var adjustedArtworkImage: NSImage?
    @State private var adjustedArtworkKey: String?
    @State private var renderKey: String = ""
    @State private var adjustedVisible: Bool = false
    @State private var processingTask: Task<Void, Never>?

    var body: some View {
        let size = CassetteLayout.cassetteSize(for: context)
        let centeredYOffset: CGFloat = showLEDMeter ? 0 : max(10, min(24, size.height * 0.07))

        ZStack {
            Image(tapeAssetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            maskedArtwork(size: size)

            Image("tapegray")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            Image("tapepaper")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .blendMode(.multiply)
                .opacity(0.40)

            Image("tapeoutline")
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
        .offset(y: centeredYOffset)
        .onAppear {
            scheduleAdjustedArtworkProcessing()
        }
        .onChange(of: context.track?.id) { _, _ in
            scheduleAdjustedArtworkProcessing()
        }
        .onChange(of: context.track?.artworkData?.count) { _, _ in
            scheduleAdjustedArtworkProcessing()
        }
        .onChange(of: context.theme.colorScheme) { _, _ in
            scheduleAdjustedArtworkProcessing()
        }
        .onDisappear {
            processingTask?.cancel()
        }
    }

    @ViewBuilder
    private func maskedArtwork(size: CGSize) -> some View {
        ZStack {
            originalArtworkImage
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(showAdjustedLayer ? 0 : 1)

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
            Image("tapemask")
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

    private func scheduleAdjustedArtworkProcessing() {
        processingTask?.cancel()

        guard let track = context.track, let data = track.artworkData else {
            renderKey = ""
            adjustedArtworkKey = nil
            adjustedArtworkImage = nil
            adjustedVisible = false
            return
        }

        let lo = 0.08
        let hi = (context.theme.colorScheme == .dark) ? 0.80 : 0.83
        let midAnchor = 0.5
        let seed = UInt64(bitPattern: Int64(track.id.uuidString.hashValue))
        let key = makeToneKey(
            trackID: track.id,
            scheme: context.theme.colorScheme,
            lo: lo,
            hi: hi,
            mid: midAnchor,
            checksum: fastChecksum(data)
        )
        renderKey = key
        adjustedVisible = false

        processingTask = Task(priority: .utility) {
            if let cached = await CassetteArtworkCache.shared.data(for: key),
                !Task.isCancelled
            {
                await MainActor.run {
                    guard self.renderKey == key else { return }
                    guard let cachedImage = NSImage(data: cached) else { return }
                    self.adjustedArtworkImage = cachedImage
                    self.adjustedArtworkKey = key
                    withAnimation(.easeInOut(duration: 0.26)) {
                        self.adjustedVisible = true
                    }
                }
                return
            }

            let result = await Task.detached(priority: .utility) {
                CassetteArtworkToneMapper.process(
                    data: data,
                    lo: lo,
                    hi: hi,
                    midAnchor: midAnchor,
                    seed: seed
                )
            }.value

            guard !Task.isCancelled, let result else {
                return
            }

            await CassetteArtworkCache.shared.setData(result.data, for: key)
            await MainActor.run {
                guard self.renderKey == key else { return }
                guard let image = NSImage(data: result.data) else { return }
                self.adjustedArtworkImage = image
                self.adjustedArtworkKey = key
                withAnimation(.easeInOut(duration: 0.26)) {
                    self.adjustedVisible = true
                }
            }
        }
    }

    private func makeToneKey(
        trackID: UUID,
        scheme: ColorScheme,
        lo: Double,
        hi: Double,
        mid: Double,
        checksum: UInt64
    ) -> String {
        "\(trackID.uuidString)-\(scheme == .dark ? "dark" : "light")-\(String(format: "%.3f", lo))-\(String(format: "%.3f", hi))-\(String(format: "%.3f", mid))-\(checksum)"
    }

    private func fastChecksum(_ data: Data) -> UInt64 {
        if data.isEmpty { return 0 }
        var hash: UInt64 = 1_469_598_103_934_665_603
        let stride = max(1, data.count / 512)
        var index = 0
        while index < data.count {
            hash ^= UInt64(data[index])
            hash = hash &* 1_099_511_628_211
            index += stride
        }
        hash ^= UInt64(data.count)
        return hash
    }
}

private struct CassetteLumaStats: Sendable {
    let low: Double
    let high: Double
    let mean: Double
}

private actor CassetteArtworkCache {
    static let shared = CassetteArtworkCache()

    private var storage: [String: Data] = [:]
    private var keys: [String] = []
    private let maxCount = 48

    func data(for key: String) -> Data? {
        storage[key]
    }

    func setData(_ data: Data, for key: String) {
        if storage[key] == nil {
            keys.append(key)
        }
        storage[key] = data
        while keys.count > maxCount {
            let oldest = keys.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}

private enum CassetteArtworkToneMapper {
    nonisolated static func process(
        data: Data,
        lo: Double,
        hi: Double,
        midAnchor: Double,
        seed: UInt64
    ) -> (data: Data, before: CassetteLumaStats, after: CassetteLumaStats)? {
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        guard let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        guard let input = CIImage(data: data), !input.extent.isEmpty else { return nil }

        let linearInput = input.applyingFilter("CISRGBToneCurveToLinear")
        guard
            let before = sampledLumaStats(
                from: linearInput, seed: seed, ciContext: ciContext, linearSpace: linearSpace)
        else { return nil }

        // Only downshift exposure to tame highlights; never raise whole image for low-end.
        let exposureEV: Double = before.high > hi ? (log2(hi / before.high) * 0.85) : 0
        let exposedLinear =
            exposureEV < 0
            ? linearInput.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposureEV])
            : linearInput

        // S-curve: keep mid anchor, slight toe lift only when very dark, compress shoulder near hi.
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

        // Very weak dither to reduce banding.
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

        // Final hard cap only for highlights; no hard floor on shadows.
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
            let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent),
            let pngData = ciContext.pngRepresentation(
                of: CIImage(cgImage: cgImage),
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [:]
            ),
            let after = sampledLumaStats(
                from: clampedLinear,
                seed: seed &+ 0xB529_7A4D,
                ciContext: ciContext,
                linearSpace: linearSpace
            )
        else { return nil }

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

        return (pngData, before, after)
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

private struct WaveformCapsulesLayer: View {
    let context: SkinContext
    @State private var vm = AudioVisualizationService.shared

    // MARK: - Constants (Manual Tuning)
    private enum Constants {
        // Position
        static let cx: CGFloat = 0.501
        static let cy: CGFloat = 0.542

        // Layout
        static let capsuleCount = 9
        static let capsuleWidthRatio: CGFloat = 0.01  // Width relative to container width
        static let spacingRatio: CGFloat = 0.017  // Spacing relative to container width

        // Height Scaling
        static let maxBarHeightRatio: CGFloat = 0.14
        static let heightBoost: CGFloat = 1.0

        // Color Tuning (Dark/Light Mode Clamps)
        static let darkBrightnessMin: CGFloat = 0.10
        static let darkBrightnessMax: CGFloat = 0.14
        static let lightBrightnessMax: CGFloat = 0.55
    }

    @State private var artworkPalette: [NSColor] = []

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let barWidth = w * Constants.capsuleWidthRatio
            let minH = barWidth
            let maxH = h * Constants.maxBarHeightRatio

            let spacing = w * Constants.spacingRatio
            let totalWidth =
                (CGFloat(Constants.capsuleCount) * barWidth)
                + (CGFloat(Constants.capsuleCount - 1) * spacing)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Constants.capsuleCount, id: \.self) { i in
                    let val = CGFloat(vm.wave9[i])
                    let dynamicH = minH + (maxH - minH) * val

                    Capsule()
                        .fill(capsuleColor(at: i, total: Constants.capsuleCount))
                        .frame(width: barWidth, height: dynamicH)
                }
            }
            .frame(width: totalWidth, height: maxH * 2.5, alignment: .center)
            .position(x: w * Constants.cx, y: h * Constants.cy)
        }
        .allowsHitTesting(false)
        .onAppear {
            vm.start()
            vm.updatePlaybackState(isPlaying: context.playback.isPlaying)
            updateArtworkColors()
        }
        .onDisappear {
            vm.stop()
        }
        .onChange(of: context.track?.id) { _, _ in
            updateArtworkColors()
        }
        .onChange(of: context.playback.isPlaying) { _, isPlaying in
            vm.updatePlaybackState(isPlaying: isPlaying)
        }
    }

    private func updateArtworkColors() {
        if let data = context.track?.artworkData {
            // Reusing uiThemePalette (palettePrimary/Secondary) logic
            artworkPalette = ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 2)
        } else {
            artworkPalette = []
        }
    }

    private func capsuleColor(at index: Int, total: Int) -> Color {
        let t = total > 1 ? CGFloat(index) / CGFloat(total - 1) : 0

        // Use artworkAccentColor as fallback if palette extraction fails
        let leftBase: NSColor
        let rightBase: NSColor

        if artworkPalette.count >= 2 {
            leftBase = artworkPalette[0]
            rightBase = artworkPalette[1]
        } else {
            let accent = NSColor(context.theme.artworkAccentColor ?? .white)
            leftBase = accent
            rightBase = accent.withAlphaComponent(0.7)
        }

        // RGB interpolation
        guard let c1 = leftBase.usingColorSpace(.deviceRGB),
            let c2 = rightBase.usingColorSpace(.deviceRGB)
        else {
            return Color(nsColor: leftBase)
        }

        let r = c1.redComponent + (c2.redComponent - c1.redComponent) * t
        let g = c1.greenComponent + (c2.greenComponent - c1.greenComponent) * t
        let b = c1.blueComponent + (c2.blueComponent - c1.blueComponent) * t

        let interpolated = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)

        var h: CGFloat = 0
        var s: CGFloat = 0
        var bri: CGFloat = 0
        var a: CGFloat = 0
        interpolated.getHue(&h, saturation: &s, brightness: &bri, alpha: &a)

        let targetBrightness: CGFloat
        let targetAlpha: CGFloat

        if context.theme.colorScheme == .dark {
            // Apply strict brightness clamp (0.11 - 0.17)
            // Scaling the original brightness down before clamping to keep relative tones
            targetBrightness = max(
                Constants.darkBrightnessMin, min(Constants.darkBrightnessMax, bri * 0.4))
            targetAlpha = 0.8
            s *= 0.9  // Slightly desaturate for heavy dark feel
        } else {
            // Light mode: moderately dark for contrast on light tape, capped at lightBrightnessMax
            targetBrightness = min(max(0.1, bri * 0.7), Constants.lightBrightnessMax)
            targetAlpha = 0.85
        }

        return Color(
            nsColor: NSColor(
                hue: h, saturation: s, brightness: targetBrightness, alpha: targetAlpha))
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
                .animation(minimumInterval: isStationary ? 1.0 : 1.0 / 120.0, paused: isStationary)
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
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

private struct CassetteOverlay: View {
    let context: SkinContext
    @AppStorage("skin.kmgcccCassette.showLEDMeter") private var showLEDMeter: Bool = false

    var body: some View {
        let size = CassetteLayout.cassetteSize(for: context)
        let yOffset = size.height / 2 + CassetteLayout.ledGap

        Group {
            if showLEDMeter {
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: 12,
                    spacing: 8,
                    pillTint: context.theme.artworkAccentColor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: yOffset)
            }
        }
    }
}

private struct KmgcccCassetteSettingsView: View {
    @AppStorage("skin.kmgcccCassette.showLEDMeter") private var showLEDMeter: Bool = false
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var showKmgLook: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                NSLocalizedString("skin.kmgccc_cassette.show_led", comment: ""), isOn: $showLEDMeter
            )
            .toggleStyle(.switch)

            Toggle(
                NSLocalizedString("skin.kmgccc_cassette.show_kmg", comment: ""), isOn: $showKmgLook
            )
            .toggleStyle(.switch)
        }
    }
}
