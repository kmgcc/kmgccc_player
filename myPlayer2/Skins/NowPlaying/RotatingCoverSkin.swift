//
//  RotatingCoverSkin.swift
//  myPlayer2
//
//  kmgccc_player - Rotating Cover Skin
//

import AppKit
import Combine
import CoreImage
import CryptoKit
import SwiftUI

struct RotatingCoverSkin: NowPlayingSkin {
    static let id: String = "rotatingCover"

    let id: String = RotatingCoverSkin.id
    let name: String = NSLocalizedString("skin.rotating_cover.name", comment: "")
    let detail: String = NSLocalizedString("skin.rotating_cover.detail", comment: "")
    let systemImage: String = "record.circle"
    var isFullscreenCompatible: Bool { true }
    var isNowPlayingCompatible: Bool { true }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(RotatingCoverArtwork(context: context))
    }

    var settingsView: AnyView? {
        AnyView(RotatingCoverSkinNormalSettingsView())
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(RotatingCoverSkinFullscreenSettingsView())
    }
}

private enum RotatingCoverLayout {
    private static let classicWindowScaleFactor: CGFloat = 0.5
    private static let classicFullscreenScaleFactor: CGFloat = 0.6
    private static let classicWindowMaxSize: CGFloat = 360
    private static let classicFullscreenMaxSize: CGFloat = 480
    private static let classicMinSize: CGFloat = 180
    private static let classicFullscreenArtworkBoost: CGFloat = 1.22
    private static let classicFullscreenVisualScale: CGFloat = 1.2
    private static let baseExpansionRatio: CGFloat = 1.12
    private static let fullscreenSharedBaseXOffset: CGFloat = -8
    private static let embeddedFullscreenYOffset: CGFloat = 12

    static let discToBaseRatio: CGFloat = 0.75
    static let yOffsetWindow: CGFloat = 18
    static let yOffsetFullscreen: CGFloat = 32

    struct Metrics {
        let discSize: CGFloat
        let baseSize: CGFloat
        let xOffset: CGFloat
        let yOffset: CGFloat
    }

    static func metrics(for context: SkinContext, isFullscreen: Bool) -> Metrics {
        let baseSize = expandedBaseVisualSize(for: context, isFullscreen: isFullscreen)
        let discSize = baseSize * discToBaseRatio
        let xOffset = FullscreenCoverHorizontalOffset.artworkOffsetX(
            for: context,
            baseOffset: fullscreenSharedBaseXOffset
        )
        let yOffset: CGFloat
        if isFullscreen {
            yOffset = context.fullscreenHostMode == .embeddedWindow
                ? embeddedFullscreenYOffset
                : yOffsetFullscreen
        } else {
            yOffset = yOffsetWindow
        }
        return Metrics(
            discSize: discSize,
            baseSize: baseSize,
            xOffset: xOffset,
            yOffset: yOffset
        )
    }

    private static func classicArtworkVisualSize(for context: SkinContext, isFullscreen: Bool) -> CGFloat {
        let contentSize = context.contentSize
        let artworkBoost = isFullscreen ? classicFullscreenArtworkBoost : 1.0
        let scaleFactor = isFullscreen ? classicFullscreenScaleFactor : classicWindowScaleFactor
        let maxSizeBase = isFullscreen ? classicFullscreenMaxSize : classicWindowMaxSize
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(
            contentSize.width * scaleFactor,
            contentSize.height * scaleFactor,
            maxSize
        )
        let artworkSize = max(classicMinSize * artworkBoost, maxArtwork)
        let visualScale = isFullscreen ? classicFullscreenVisualScale : 1.0
        return artworkSize * visualScale
    }

    private static func expandedBaseVisualSize(for context: SkinContext, isFullscreen: Bool) -> CGFloat {
        let classicVisualSize = classicArtworkVisualSize(for: context, isFullscreen: isFullscreen)
        let contentSize = context.contentSize
        let absoluteCap = min(
            contentSize.width * (isFullscreen ? 0.84 : 0.68),
            contentSize.height * (isFullscreen ? 0.84 : 0.68)
        )
        return min(classicVisualSize * baseExpansionRatio, absoluteCap)
    }
}

private struct RotationProfile {
    let maxSpeed: Double
    let startTau: Double
    let stopTau: Double
}

private enum RotatingCoverDiscMode {
    case vinyl
    case cd

    var profile: RotationProfile {
        switch self {
        case .vinyl:
            return RotationProfile(
                maxSpeed: 12.0,
                startTau: 0.50,
                stopTau: 1.20
            )
        case .cd:
            return RotationProfile(
                maxSpeed: 3100.0,
                startTau: 0.40,
                stopTau: 0.68
            )
        }
    }
}

@MainActor
private final class RotatingCoverRotation: ObservableObject {
    let anglePublisher = CurrentValueSubject<Double, Never>(0)
    let speedRatioPublisher = CurrentValueSubject<Double, Never>(0)

    private var velocity: Double = 0
    private var targetVelocity: Double = 0
    private var lastTime: TimeInterval = 0
    private var motionEnabled: Bool = true
    private var timerCancellable: AnyCancellable?
    private var profile: RotationProfile = RotatingCoverDiscMode.vinyl.profile
    private var angle: Double = 0

    private let restEpsilon: Double = 0.05

    func setPlaying(_ isPlaying: Bool) {
        targetVelocity = motionEnabled && isPlaying ? profile.maxSpeed : 0
        updateTickerState()
    }

    func setMode(_ mode: RotatingCoverDiscMode, isPlaying: Bool) {
        profile = mode.profile
        targetVelocity = motionEnabled && isPlaying ? profile.maxSpeed : 0
        updateTickerState()
    }

    func setMotionEnabled(_ isEnabled: Bool, isPlaying: Bool) {
        guard motionEnabled != isEnabled else {
            targetVelocity = isEnabled && isPlaying ? profile.maxSpeed : 0
            updateTickerState()
            return
        }

        motionEnabled = isEnabled
        if motionEnabled {
            lastTime = 0
            targetVelocity = isPlaying ? profile.maxSpeed : 0
            updateTickerState()
        } else {
            targetVelocity = 0
            velocity = 0
            lastTime = 0
            speedRatioPublisher.send(0)
            stopTicker()
        }
    }

    func reset() {
        angle = 0
        anglePublisher.send(angle)
        velocity = 0
        targetVelocity = 0
        lastTime = 0
        speedRatioPublisher.send(0)
        stopTicker()
    }

    func suspend() {
        lastTime = 0
        stopTicker()
    }

    func tick(at date: Date) {
        guard motionEnabled else { return }

        let now = date.timeIntervalSinceReferenceDate

        // First tick init
        if lastTime == 0 {
            lastTime = now
            return
        }

        var dt = now - lastTime
        lastTime = now
        if dt > 0.1 { dt = 1.0 / 60.0 }  // Prevent jumps on resume

        let tau = targetVelocity > velocity ? profile.startTau : profile.stopTau
        let decay = exp(-dt / tau)
        velocity = targetVelocity + (velocity - targetVelocity) * decay
        if abs(velocity - targetVelocity) < restEpsilon {
            velocity = targetVelocity
        }

        if velocity == 0, targetVelocity == 0 {
            speedRatioPublisher.send(0)
            stopTicker()
            return
        }

        angle += velocity * dt

        angle.formTruncatingRemainder(dividingBy: 360)
        if angle < 0 {
            angle += 360
        }
        anglePublisher.send(angle)
        speedRatioPublisher.send(min(abs(velocity) / max(profile.maxSpeed, 0.001), 1))
    }

    private func updateTickerState() {
        guard motionEnabled else {
            stopTicker()
            return
        }

        let shouldTick = targetVelocity != 0 || abs(velocity) > restEpsilon
        if shouldTick {
            startTickerIfNeeded()
        } else {
            velocity = 0
            lastTime = 0
            stopTicker()
        }
    }

    private func startTickerIfNeeded() {
        guard timerCancellable == nil else { return }
        timerCancellable = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.tick(at: date)
            }
    }

    private func stopTicker() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }
}

@MainActor
private final class RotatingCoverCDMotionBlurCache: ObservableObject {
    @Published private(set) var blurredImage: NSImage?

    private static let blurVersion = 6
    private static let maxRenderPixelSize = 640
    private static let minRenderableDiscSize: CGFloat = 24

    private struct CacheKey: Equatable, Sendable {
        let artworkSignature: String
        let pixelSize: Int
        let version: Int
    }

    private var currentKey: CacheKey?
    private var renderTask: Task<Void, Never>?

    deinit {
        renderTask?.cancel()
    }

    func update(
        artworkImage: NSImage?,
        artworkSignature: String?,
        discSize: CGFloat,
        enabled: Bool
    ) {
        guard
            enabled,
            discSize.isFinite,
            discSize >= Self.minRenderableDiscSize,
            let artworkImage,
            let artworkSignature,
            let sourceImage = artworkImage.cgImageSnapshot()
        else {
            clear()
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let quantizedSize = quantizedPixelSize(for: discSize * scale)
        guard quantizedSize > 0 else {
            clear()
            return
        }
        let pixelSize = max(min(quantizedSize, Self.maxRenderPixelSize), 96)
        let key = CacheKey(
            artworkSignature: artworkSignature,
            pixelSize: pixelSize,
            version: Self.blurVersion
        )
        let previousKey = currentKey

        guard currentKey != key else { return }
        currentKey = key

        renderTask?.cancel()
        if previousKey?.artworkSignature != key.artworkSignature {
            blurredImage = nil
        }

        let targetDiscSize = discSize
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let rendered = autoreleasepool {
                guard !Task.isCancelled else { return nil as CGImage? }
                return RotatingCoverCDMotionBlurRenderer.render(
                    sourceImage: sourceImage,
                    pixelSize: pixelSize
                )
            }
            guard !Task.isCancelled, let rendered else { return }
            await MainActor.run {
                guard let self, self.currentKey == key else { return }
                self.blurredImage = NSImage(
                    cgImage: rendered,
                    size: NSSize(width: targetDiscSize, height: targetDiscSize)
                )
            }
        }
    }

    func clear() {
        renderTask?.cancel()
        renderTask = nil
        currentKey = nil
        blurredImage = nil
    }

    private func quantizedPixelSize(for rawPixelSize: CGFloat) -> Int {
        guard rawPixelSize.isFinite, rawPixelSize > 0 else { return 0 }
        let bucket: CGFloat = 12
        return Int((rawPixelSize / bucket).rounded(.toNearestOrAwayFromZero) * bucket)
    }
}

// MARK: - CD motion blur renderer (fully nonisolated)
//
// All rendering work runs off the main actor on a detached Task. Members are
// declared `nonisolated` so the closure captured by Task.detached cannot
// inherit any actor isolation from the caller — that inheritance was the
// remaining cause of `_dispatch_assert_queue_fail` after the previous patch.
private enum RotatingCoverCDMotionBlurRenderer {
    nonisolated static let ciContext = CIContext(options: nil)
    nonisolated private static let angularBlurRadiusDegrees: CGFloat = 180
    nonisolated private static let angularSampleStepDegrees: CGFloat = 0.75
    nonisolated private static let angularBlurAccumulationAlpha: CGFloat = 24.0

    nonisolated static func render(sourceImage: CGImage, pixelSize: Int) -> CGImage? {
        guard
            pixelSize > 1,
            sourceImage.width > 0,
            sourceImage.height > 0
        else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        let sampleOffsets = stride(
            from: -angularBlurRadiusDegrees,
            through: angularBlurRadiusDegrees,
            by: angularSampleStepDegrees
        ).map(CGFloat.init)
        let maxOffset = angularBlurRadiusDegrees
        let sampleWeights = sampleOffsets.map { angle in
            let normalizedDistance = abs(angle) / maxOffset
            return 0.62 + pow(1 - normalizedDistance, 0.55) * 0.86
        }
        let weightSum = sampleWeights.reduce(0, +)
        let drawRect = aspectFillRect(
            sourceSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            targetRect: bounds
        )

        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.addEllipse(in: CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height))
        context.clip()

        for (index, pair) in zip(sampleOffsets, sampleWeights).enumerated() {
            if index.isMultiple(of: 8), Task.isCancelled {
                return nil
            }
            let (angle, weight) = pair
            context.saveGState()
            context.rotate(by: angle * .pi / 180)
            context.setAlpha(weight / weightSum * angularBlurAccumulationAlpha)
            context.draw(
                sourceImage,
                in: CGRect(
                    x: drawRect.origin.x - bounds.midX,
                    y: drawRect.origin.y - bounds.midY,
                    width: drawRect.width,
                    height: drawRect.height
                )
            )
            context.restoreGState()
        }
        context.restoreGState()

        guard let compositedImage = context.makeImage() else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let lightlyBlurred = lightlyBlurredImage(from: compositedImage, pixelSize: pixelSize) else {
            return compositedImage
        }
        guard !Task.isCancelled else { return nil }
        return densifiedOpaqueBlurImage(from: lightlyBlurred, pixelSize: pixelSize, colorSpace: colorSpace)
    }

    nonisolated private static func lightlyBlurredImage(from image: CGImage, pixelSize: Int) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let blurred = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4.0])
            .cropped(to: bounds)
        return ciContext.createCGImage(blurred, from: bounds)
    }

    nonisolated private static func densifiedOpaqueBlurImage(
        from image: CGImage,
        pixelSize: Int,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let fillColor = averageFillColor(from: image, colorSpace: colorSpace) else {
            return image
        }
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.addEllipse(in: bounds)
        context.clip()
        context.setFillColor(fillColor)
        context.fill(bounds)

        // Re-composite the finished blur image over an opaque disc fill so
        // the motion layer itself covers the artwork/background instead of
        // relying on reducing the base artwork layer.
        context.setBlendMode(.normal)
        context.setAlpha(1.0)
        context.draw(image, in: bounds)
        context.setAlpha(1.0)
        context.draw(image, in: bounds)
        context.setAlpha(0.86)
        context.draw(image, in: bounds)

        return context.makeImage()
    }

    nonisolated private static func averageFillColor(
        from image: CGImage,
        colorSpace: CGColorSpace
    ) -> CGColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let didDraw = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard didDraw else { return nil }
        let alpha = max(CGFloat(pixel[3]) / 255, 0.001)
        let red = min(1, CGFloat(pixel[0]) / 255 / alpha)
        let green = min(1, CGFloat(pixel[1]) / 255 / alpha)
        let blue = min(1, CGFloat(pixel[2]) / 255 / alpha)
        return CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])
    }
}

private nonisolated func aspectFillRect(sourceSize: CGSize, targetRect: CGRect) -> CGRect {
    guard
        sourceSize.width.isFinite,
        sourceSize.height.isFinite,
        sourceSize.width > 0,
        sourceSize.height > 0
    else {
        return targetRect
    }
    let scale = max(targetRect.width / sourceSize.width, targetRect.height / sourceSize.height)
    let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    return CGRect(
        x: targetRect.midX - scaledSize.width / 2,
        y: targetRect.midY - scaledSize.height / 2,
        width: scaledSize.width,
        height: scaledSize.height
    )
}

private extension NSImage {
    func cgImageSnapshot() -> CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func blurCacheSignature(trackID: UUID?) -> String {
        if let trackID {
            return "track:\(trackID.uuidString)"
        }

        if let tiffRepresentation {
            let digest = SHA256.hash(data: tiffRepresentation)
            return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        }

        return "size:\(Int(size.width))x\(Int(size.height))"
    }
}

private struct RotatingCoverDiscStack<DiscView: View>: View {
    let context: SkinContext
    let baseSize: CGFloat
    let discView: DiscView

    init(
        context: SkinContext,
        baseSize: CGFloat,
        @ViewBuilder discView: () -> DiscView
    ) {
        self.context = context
        self.baseSize = baseSize
        self.discView = discView()
    }

    var body: some View {
        ZStack(alignment: .center) {
            Circle()
                .frame(width: baseSize, height: baseSize)
                .liquidGlassCircle(
                    colorScheme: context.theme.colorScheme,
                    isFloating: false
                )

            discView
                .frame(width: baseSize, height: baseSize, alignment: .center)
        }
        .frame(width: baseSize, height: baseSize, alignment: .center)
    }
}

private struct RotatingDiscLayerView<Content: View>: NSViewRepresentable {
    let rotation: RotatingCoverRotation
    let baseSize: CGFloat
    let discSize: CGFloat
    let content: Content

    init(
        rotation: RotatingCoverRotation,
        baseSize: CGFloat,
        discSize: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.rotation = rotation
        self.baseSize = baseSize
        self.discSize = discSize
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rotation: rotation)
    }

    func makeNSView(context: Context) -> RotatingDiscHostView {
        let view = RotatingDiscHostView(rootView: AnyView(content), discSize: discSize)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: RotatingDiscHostView, context: Context) {
        nsView.setRootView(AnyView(content))
        nsView.updateDiscSize(discSize)
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        private let rotation: RotatingCoverRotation
        private var angleCancellable: AnyCancellable?
        private weak var hostView: RotatingDiscHostView?

        init(rotation: RotatingCoverRotation) {
            self.rotation = rotation
        }

        func attach(to view: RotatingDiscHostView) {
            guard hostView !== view else { return }
            hostView = view
            angleCancellable?.cancel()
            angleCancellable = rotation.anglePublisher
                .sink { [weak view] angle in
                    view?.setRotationAngle(angle)
                }
        }
    }
}

private final class RotatingDiscHostView: NSView {
    private let hostingView: NSHostingView<AnyView>
    private let widthConstraint: NSLayoutConstraint
    private let heightConstraint: NSLayoutConstraint

    init(rootView: AnyView, discSize: CGFloat) {
        hostingView = NSHostingView(rootView: rootView)
        let safeDiscSize = Self.sanitizedDiscSize(discSize)
        widthConstraint = hostingView.widthAnchor.constraint(equalToConstant: safeDiscSize)
        heightConstraint = hostingView.heightAnchor.constraint(equalToConstant: safeDiscSize)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        hostingView.layer?.shouldRasterize = true
        hostingView.layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2

        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            hostingView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthConstraint,
            heightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRootView(_ rootView: AnyView) {
        hostingView.rootView = rootView
    }

    func updateDiscSize(_ discSize: CGFloat) {
        let safeDiscSize = Self.sanitizedDiscSize(discSize)
        widthConstraint.constant = safeDiscSize
        heightConstraint.constant = safeDiscSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateRotationAnchor()
    }

    func setRotationAngle(_ angle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateRotationAnchor()
        hostingView.layer?.transform = CATransform3DMakeRotation(CGFloat(-angle * .pi / 180), 0, 0, 1)
        CATransaction.commit()
    }

    private func updateRotationAnchor() {
        guard let layer = hostingView.layer else { return }
        let position = CGPoint(x: bounds.midX, y: bounds.midY)
        guard position.x.isFinite, position.y.isFinite else { return }
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        if layer.position != position {
            layer.position = position
        }
    }

    private static func sanitizedDiscSize(_ discSize: CGFloat) -> CGFloat {
        guard discSize.isFinite, discSize > 0 else { return 0 }
        return discSize
    }
}

private struct RotatingCDDiscLayerView: NSViewRepresentable {
    let rotation: RotatingCoverRotation
    let baseSize: CGFloat
    let discSize: CGFloat
    let artworkImage: NSImage
    let blurredImage: NSImage?

    func makeCoordinator() -> Coordinator {
        Coordinator(rotation: rotation)
    }

    func makeNSView(context: Context) -> RotatingCDDiscHostView {
        let view = RotatingCDDiscHostView()
        view.updateGeometry(discSize: discSize)
        view.updateImages(artworkImage: artworkImage, blurredImage: blurredImage)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: RotatingCDDiscHostView, context: Context) {
        nsView.updateGeometry(discSize: discSize)
        nsView.updateImages(artworkImage: artworkImage, blurredImage: blurredImage)
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: RotatingCDDiscHostView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.dismantle()
    }

    final class Coordinator {
        private let rotation: RotatingCoverRotation
        private var angleCancellable: AnyCancellable?
        private var speedCancellable: AnyCancellable?
        private weak var hostView: RotatingCDDiscHostView?

        init(rotation: RotatingCoverRotation) {
            self.rotation = rotation
        }

        func attach(to view: RotatingCDDiscHostView) {
            guard hostView !== view else { return }
            hostView = view
            angleCancellable?.cancel()
            speedCancellable?.cancel()

            angleCancellable = rotation.anglePublisher
                .sink { [weak view] angle in
                    view?.setRotationAngle(angle)
                }

            speedCancellable = rotation.speedRatioPublisher
                .sink { [weak view] ratio in
                    view?.setBlurStrength(ratio)
                }
        }

        func detach() {
            angleCancellable?.cancel()
            angleCancellable = nil
            speedCancellable?.cancel()
            speedCancellable = nil
            hostView = nil
        }
    }
}

private final class RotatingCDDiscHostView: NSView {
    private let discRootLayer = CALayer()
    private let blurLayer = CALayer()
    private let artworkLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private var discSize: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(discRootLayer)

        discRootLayer.masksToBounds = false
        discRootLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        blurLayer.contentsGravity = .resizeAspectFill
        blurLayer.masksToBounds = true
        blurLayer.isOpaque = true
        blurLayer.opacity = 0
        blurLayer.minificationFilter = .trilinear
        blurLayer.magnificationFilter = .trilinear

        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.masksToBounds = true
        artworkLayer.isOpaque = true
        artworkLayer.minificationFilter = .trilinear
        artworkLayer.magnificationFilter = .trilinear

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        borderLayer.lineWidth = 1

        discRootLayer.addSublayer(artworkLayer)
        discRootLayer.addSublayer(blurLayer)
        discRootLayer.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard discSize.isFinite, discSize > 1 else {
            discRootLayer.bounds = .zero
            blurLayer.frame = .zero
            artworkLayer.frame = .zero
            borderLayer.frame = .zero
            borderLayer.path = nil
            return
        }

        let discBounds = CGRect(origin: .zero, size: CGSize(width: discSize, height: discSize))
        discRootLayer.bounds = discBounds
        blurLayer.frame = discBounds
        artworkLayer.frame = discBounds
        blurLayer.cornerRadius = discBounds.width / 2
        artworkLayer.cornerRadius = discBounds.width / 2
        borderLayer.frame = discBounds
        borderLayer.path = CGPath(ellipseIn: discBounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        updateRotationAnchor()
    }

    func updateGeometry(discSize: CGFloat) {
        self.discSize = discSize.isFinite && discSize > 0 ? discSize : 0
        needsLayout = true
    }

    func updateImages(artworkImage: NSImage, blurredImage: NSImage?) {
        artworkLayer.contents = artworkImage.cgImageSnapshot()
        artworkLayer.opacity = 1
        blurLayer.contents = blurredImage?.cgImageSnapshot()
        blurLayer.isHidden = blurredImage == nil
        if blurredImage == nil {
            blurLayer.opacity = 0
        }
    }

    func dismantle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        discRootLayer.removeAllAnimations()
        blurLayer.removeAllAnimations()
        artworkLayer.removeAllAnimations()
        borderLayer.removeAllAnimations()
        blurLayer.contents = nil
        artworkLayer.contents = nil
        blurLayer.opacity = 0
        CATransaction.commit()
    }

    func setRotationAngle(_ angle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateRotationAnchor()
        discRootLayer.transform = CATransform3DMakeRotation(CGFloat(-angle * .pi / 180), 0, 0, 1)
        CATransaction.commit()
    }

    func setBlurStrength(_ ratio: Double) {
        // Smooth fade with no cutoff. At playback speed the CD blur layer is
        // fully opaque; the base artwork layer must remain opaque too.
        let clamped = max(0, min(ratio, 1))
        let smoothed = clamped * clamped * (3 - 2 * clamped)
        let baseCoverage = smoothed > 0 ? pow(smoothed, 0.16) : 0
        let coverage: Double
        if smoothed > 0.20 {
            coverage = 1.0
        } else if smoothed > 0.04 {
            coverage = max(baseCoverage, 0.96)
        } else {
            coverage = baseCoverage
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurLayer.opacity = Float(coverage)
        artworkLayer.opacity = 1
        CATransaction.commit()
    }

    private func updateRotationAnchor() {
        let position = CGPoint(x: bounds.midX, y: bounds.midY)
        guard position.x.isFinite, position.y.isFinite else { return }
        if discRootLayer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            discRootLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        if discRootLayer.position != position {
            discRootLayer.position = position
        }
    }
}

private struct RotatingCoverArtwork: View {
    let context: SkinContext
    @StateObject private var rotation = RotatingCoverRotation()
    @StateObject private var cdMotionBlurCache = RotatingCoverCDMotionBlurCache()

    @AppStorage("skin.rotatingCover.cdMode") private var cdMode: Bool = false
    @AppStorage("skin.rotatingCover.visualizerMode") private var normalVisualizerMode: String = "off"
    @AppStorage("skin.rotatingCover.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    @State private var lastTrackID: UUID? = nil

    private var discMode: RotatingCoverDiscMode {
        cdMode ? .cd : .vinyl
    }

    private var artworkSignature: String? {
        context.track?.artworkImage?.blurCacheSignature(trackID: nil)
    }

    var body: some View {
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout
        let layout = RotatingCoverLayout.metrics(for: context, isFullscreen: usesFullscreenLayout)
        let visualizerMode = usesFullscreenLayout ? fullscreenVisualizerMode : normalVisualizerMode
        let reduceMotion = context.theme.reduceMotion

        VStack(spacing: 32) {
            RotatingCoverDiscStack(
                context: context,
                baseSize: layout.baseSize
            ) {
                if discMode == .cd, let artworkImage = context.track?.artworkImage {
                    RotatingCDDiscLayerView(
                        rotation: rotation,
                        baseSize: layout.baseSize,
                        discSize: layout.discSize,
                        artworkImage: artworkImage,
                        blurredImage: cdMotionBlurCache.blurredImage
                    )
                    .frame(width: layout.baseSize, height: layout.baseSize)
                } else {
                    RotatingDiscLayerView(
                        rotation: rotation,
                        baseSize: layout.baseSize,
                        discSize: layout.discSize
                    ) {
                        artworkView(size: layout.discSize)
                    }
                    .frame(width: layout.baseSize, height: layout.baseSize)
                }
            }

            if visualizerMode == "led" {
                let usesFullscreen = usesFullscreenLayout
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: usesFullscreen ? 16 : 14,
                    spacing: usesFullscreen ? 10 : 8,
                    pillTint: context.theme.artworkAccentColor,
                    isPlaying: context.playback.isPlaying,
                    forceBrightLEDColors: context.theme.artBackgroundIsUltraDark
                )
            } else if visualizerMode == "spectrum" {
                PillSpectrumView(
                    context: context,
                    dotSize: 12,
                    spacing: 8,
                    pillTint: context.theme.artworkAccentColor,
                    isFullscreen: usesFullscreenLayout
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: layout.xOffset, y: layout.yOffset)
        .onAppear {
            lastTrackID = context.track?.id
            rotation.setMode(discMode, isPlaying: context.playback.isPlaying)
            rotation.setMotionEnabled(!reduceMotion, isPlaying: context.playback.isPlaying)
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: context.playback.isPlaying) { _, isPlaying in
            rotation.setPlaying(isPlaying)
        }
        .onChange(of: cdMode) { _, _ in
            rotation.setMode(discMode, isPlaying: context.playback.isPlaying)
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: reduceMotion) { _, isReduced in
            rotation.setMotionEnabled(!isReduced, isPlaying: context.playback.isPlaying)
        }
        .onChange(of: Int(layout.discSize.rounded())) { _, _ in
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: artworkSignature) { _, _ in
            updateCDMotionBlurCache(discSize: layout.discSize)
        }
        .onChange(of: context.track?.id) { _, newID in
            if newID != lastTrackID {
                lastTrackID = newID
                cdMotionBlurCache.clear()
                rotation.reset()
                rotation.setMode(discMode, isPlaying: context.playback.isPlaying)
            }
        }
        .onDisappear {
            rotation.suspend()
            cdMotionBlurCache.clear()
        }
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        } else {
            ArtworkPlaceholderView.nowPlaying(
                size: size,
                cornerRadius: 0,
                isCircle: true
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func updateCDMotionBlurCache(discSize: CGFloat) {
        cdMotionBlurCache.update(
            artworkImage: context.track?.artworkImage,
            artworkSignature: artworkSignature,
            discSize: discSize,
            enabled: discMode == .cd
        )
    }
}
private struct RotatingCoverSkinNormalSettingsView: View {
    @AppStorage("skin.rotatingCover.cdMode") private var cdMode: Bool = false
    @AppStorage("skin.rotatingCover.visualizerMode") private var visualizerMode: String = "off"
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSwitchRow(title: "CD 模式", isOn: $cdMode)

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

            SettingsSwitchRow(title: "频谱动画", isOn: Binding(
                get: { visualizerMode == "spectrum" },
                set: { isOn in
                    if isOn {
                        visualizerMode = "spectrum"
                        ledMeterProvider.releaseNowPlayingResources()
                    } else if visualizerMode == "spectrum" {
                        visualizerMode = "off"
                    }
                }
            ))
        }
    }
}

private struct RotatingCoverSkinFullscreenSettingsView: View {
    @AppStorage("skin.rotatingCover.cdMode") private var cdMode: Bool = false
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(
                title: "CD 模式",
                isOn: $cdMode,
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.primaryTextColor
            )

            SettingsSwitchRow(title: "LED 电平表", isOn: Binding(
                get: {
                    FullscreenPresentationCoordinator.shared.isSkinVisualizerEnabled
                    && UserDefaults.standard.string(forKey: "skin.rotatingCover.fullscreen.visualizerMode") == "led"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("led", forKey: "skin.rotatingCover.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                    } else {
                        UserDefaults.standard.set("off", forKey: "skin.rotatingCover.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                    }
                }
            ), titleFont: presentationStyle.rowLabelFont, titleColor: presentationStyle.primaryTextColor)

            SettingsSwitchRow(title: "频谱动画", isOn: Binding(
                get: {
                    FullscreenPresentationCoordinator.shared.isSkinVisualizerEnabled
                    && UserDefaults.standard.string(forKey: "skin.rotatingCover.fullscreen.visualizerMode") == "spectrum"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("spectrum", forKey: "skin.rotatingCover.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                    } else {
                        UserDefaults.standard.set("off", forKey: "skin.rotatingCover.fullscreen.visualizerMode")
                        FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                    }
                }
            ), titleFont: presentationStyle.rowLabelFont, titleColor: presentationStyle.primaryTextColor)
        }
    }
}

private struct PillSpectrumView: View {
    let context: SkinContext
    let dotSize: CGFloat
    let spacing: CGFloat
    let pillTint: Color?
    let isFullscreen: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let capsuleCount: CGFloat = 9
    private let capsuleWidth: CGFloat = 7
    private let capsuleSpacing: CGFloat = 10
    private let horizontalPadding: CGFloat = 28
    private let contentHeight: CGFloat = 52  // Spectrum bars height (increased from 48)
    private var verticalPadding: CGFloat {
        isFullscreen ? 5 : 8  // Slightly shorter background pill in fullscreen
    }

    private var contentWidth: CGFloat {
        capsuleCount * capsuleWidth + (capsuleCount - 1) * capsuleSpacing
    }

    private var backgroundWidth: CGFloat {
        contentWidth + horizontalPadding * 2
    }

    private var backgroundHeight: CGFloat {
        contentHeight + verticalPadding * 2
    }

    var body: some View {
        PillSpectrumContainer(
            isPlaying: context.playback.isPlaying,
            usesDarkForeground: context.theme.spectrumUsesDarkForeground,
            artworkColors: context.theme.spectrumArtworkColors,
            artworkAccentColor: NSColor(pillTint ?? .white),
            capsuleWidth: capsuleWidth,
            capsuleSpacing: capsuleSpacing
        )
        .frame(width: contentWidth, height: contentHeight)
        .background(
            Capsule()
                .fill(Color.clear)
                .frame(width: backgroundWidth, height: backgroundHeight)
                .liquidGlassPill(
                    colorScheme: colorScheme,
                    accentColor: pillTint,
                    prominence: pillTint != nil ? .prominent : .standard,
                    isFloating: false
                )
        )
    }
}

private struct PillSpectrumContainer: NSViewRepresentable {
    let isPlaying: Bool
    let usesDarkForeground: Bool
    let artworkColors: [NSColor]
    let artworkAccentColor: NSColor
    let capsuleWidth: CGFloat
    let capsuleSpacing: CGFloat

    func makeNSView(context: Context) -> PillSpectrumHostView {
        let view = PillSpectrumHostView()
        view.capsuleWidth = capsuleWidth
        view.capsuleSpacing = capsuleSpacing
        view.updatePalette(artworkColors, accentColor: artworkAccentColor, usesDarkForeground: usesDarkForeground)
        view.start()
        view.setPlayback(isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ nsView: PillSpectrumHostView, context: Context) {
        nsView.capsuleWidth = capsuleWidth
        nsView.capsuleSpacing = capsuleSpacing
        nsView.updatePalette(artworkColors, accentColor: artworkAccentColor, usesDarkForeground: usesDarkForeground)
        nsView.setPlayback(isPlaying: isPlaying)
    }

    static func dismantleNSView(_ nsView: PillSpectrumHostView, coordinator: ()) {
        nsView.stop()
    }
}

@MainActor
private final class PillSpectrumHostView: NSView {
    private let service = AudioVisualizationService.shared
    private let rootLayer = CALayer()
    private var capsuleLayers: [CALayer] = []
    private var strokeLayers: [CAShapeLayer] = []
    private var consumerID: UUID?

    private var currentWave = Array(repeating: Float(0), count: 9)
    private var cachedColors: [CGColor] = []
    private var cachedStrokeColors: [CGColor] = []
    private var paletteSignature: Int = 0
    private var lastPlaybackState: Bool?
    private var lastLayoutSize: CGSize = .zero

    var capsuleWidth: CGFloat = 6
    var capsuleSpacing: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        rootLayer.masksToBounds = false
        layer?.addSublayer(rootLayer)
        setupCapsuleLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        layoutCapsules()
    }

    func start() {
        guard consumerID == nil else { return }
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
        currentWave = Array(repeating: 0, count: 9)
        layoutCapsules()
    }

    func setPlayback(isPlaying: Bool) {
        guard lastPlaybackState != isPlaying else { return }
        lastPlaybackState = isPlaying
        service.updatePlaybackState(isPlaying: isPlaying)
    }

    func updatePalette(_ artworkColors: [NSColor], accentColor: NSColor, usesDarkForeground: Bool) {
        let signature = Self.paletteSignature(
            artworkColors: artworkColors,
            accentColor: accentColor,
            usesDarkForeground: usesDarkForeground
        )
        guard signature != paletteSignature else { return }

        paletteSignature = signature
        let (fillColors, strokeColors) = SpectrumColorResolver.resolveArtworkFaithfulColors(
            from: artworkColors,
            fallback: accentColor,
            usesDarkForeground: usesDarkForeground
        )
        cachedColors = fillColors
        cachedStrokeColors = strokeColors

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in capsuleLayers.enumerated() where index < cachedColors.count {
            layer.backgroundColor = cachedColors[index]
        }
        for (index, layer) in strokeLayers.enumerated() where index < cachedStrokeColors.count {
            layer.strokeColor = cachedStrokeColors[index]
        }
        CATransaction.commit()
    }

    private func setupCapsuleLayers() {
        capsuleLayers = (0..<9).map { _ in
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

        strokeLayers = (0..<9).map { _ in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineWidth = 0.5
            layer.actions = [
                "path": NSNull(),
                "strokeColor": NSNull(),
            ]
            rootLayer.addSublayer(layer)
            return layer
        }
    }

    private func applyWave(_ wave: [Float]) {
        var normalized = Array(repeating: Float(0), count: 9)
        for index in 0..<9 {
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
        let capsuleCount = 9
        let maxBarHeightRatio: CGFloat = 0.95

        let barWidth = capsuleWidth
        let minHeight = barWidth
        let maxBarHeight = height * maxBarHeightRatio
        let spacing = capsuleSpacing
        let totalWidth = CGFloat(capsuleCount) * barWidth + CGFloat(capsuleCount - 1) * spacing
        let originX = (width - totalWidth) * 0.5
        let centerY = height * 0.5
        let cornerRadius = barWidth * 0.5

        rootLayer.frame = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<capsuleCount {
            let value = CGFloat(currentWave[index])
            let dynamicHeight = minHeight + (maxBarHeight - minHeight) * min(1, max(0, value))
            let x = originX + CGFloat(index) * (barWidth + spacing) + barWidth * 0.5
            let y = centerY

            let frame = CGRect(x: x - barWidth * 0.5, y: y - dynamicHeight * 0.5, width: barWidth, height: dynamicHeight)
            let layer = capsuleLayers[index]
            layer.frame = frame
            layer.cornerRadius = cornerRadius

            let strokeLayer = strokeLayers[index]
            let path = NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius)
            strokeLayer.path = path.cgPath
        }
        CATransaction.commit()
    }

    private static func paletteSignature(artworkColors: [NSColor], accentColor: NSColor, usesDarkForeground: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(usesDarkForeground)
        for color in artworkColors.prefix(2) {
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

}
