import AppKit
import AVFoundation
import CoreImage
import MotionKit
import QuartzCore
import SwiftUI

/// Displays a library-owned video's first frame with a static fallback. Fetching and
/// persistence belong to the enrichment service; this leaf only plays local media.
struct MotionArtworkView<Poster: View>: View {
    let resource: MotionArtworkResource?
    let isPlaying: Bool
    var isActive = true
    /// False outside Now Playing: a music video there simply loops.
    var followsSong = true
    let poster: Poster
    var frameProcessor: MotionArtworkFrameProcessor?
    var onFrame: ((CGImage) -> Void)?
    var frameOpacity: Double

    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.skinSceneIsActive) private var skinSceneIsActive
    @Environment(\.motionArtworkFullscreenCoordinator) private var fullscreenCoordinator
    /// Observed here so the switch applies instantly to every surface that
    /// hosts this leaf, including skins and library previews. Stored assets
    /// are untouched; the poster underneath simply stays visible.
    @AppStorage(AppSettings.motionArtworkEnabledDefaultsKey) private var motionArtworkEnabled = true
    /// A track switch starts the lyric entrance and the cover video together.
    /// Deliver a video frame immediately, then hold that frame briefly so
    /// continuous panorama rendering does not compete with the lyric entrance.
    @State private var isSettling = true
    @State private var settleTask: Task<Void, Never>?
    @State private var failedResource: MotionArtworkResource?

    init(
        resource: MotionArtworkResource?,
        isPlaying: Bool,
        isActive: Bool = true,
        followsSong: Bool = true,
        frameProcessor: MotionArtworkFrameProcessor? = nil,
        onFrame: ((CGImage) -> Void)? = nil,
        frameOpacity: Double = 1,
        @ViewBuilder poster: () -> Poster
    ) {
        self.resource = resource
        self.isPlaying = isPlaying
        self.isActive = isActive
        self.followsSong = followsSong
        self.poster = poster()
        self.frameProcessor = frameProcessor
        self.onFrame = onFrame
        self.frameOpacity = frameOpacity
    }

    private var activeResource: MotionArtworkResource? {
        guard motionArtworkEnabled, let resource, resource.url.isFileURL,
              resource != failedResource, isActive, skinSceneIsActive,
              configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion) == .full else { return nil }
        return resource
    }

    private func preparedFrame(for resource: MotionArtworkResource) -> CGImage? {
        // A music video opened halfway through a song must first seek to the
        // audible position; a cached frame from its beginning would be wrong.
        if followsSong, MotionArtworkSongClock.shared.isMusicVideo(duration: resource.duration),
           (MotionArtworkSongClock.shared.time ?? 0) + abs(MotionArtworkSongClock.shared.offset(for: resource) ?? 0) > 0.2 { return nil }
        return cacheServices.motionArtworkFirstFrameCache.cachedFrame(for: resource)
    }

    private func preparedUncroppedFrame(for resource: MotionArtworkResource) -> CGImage? {
        if followsSong, MotionArtworkSongClock.shared.isMusicVideo(duration: resource.duration),
           (MotionArtworkSongClock.shared.time ?? 0) + abs(MotionArtworkSongClock.shared.offset(for: resource) ?? 0) > 0.2 { return nil }
        return cacheServices.motionArtworkFirstFrameCache.cachedUncroppedFrame(for: resource)
    }

    private var shouldHideStationaryVisual: Bool {
        guard frameProcessor == nil, let fullscreenCoordinator else { return false }
        return fullscreenCoordinator.shouldHideStationaryCoverVisual(for: activeResource)
    }

    /// The fullscreen video layer owns the picture while the cover is hidden.
    /// Stopping the SwiftUI image state here keeps a transparent cover from
    /// rebuilding and uploading a second copy of every frame.
    private var suppressesVideoRendering: Bool {
        guard let fullscreenCoordinator, fullscreenCoordinator.isActive else { return false }
        switch fullscreenCoordinator.sourceGeometry?.handoffStyle ?? .directLiftOff {
        case .directLiftOff:
            // Resume the hidden cover while it shrinks, so the handoff frame
            // is current even when playback is paused.
            return fullscreenCoordinator.phase != .exiting
        case .maskedCrossfade:
            return fullscreenCoordinator.phase == .active
        }
    }

    var body: some View {
        poster
            // A valid motion resource owns the picture from the start. Keep
            // layout, but never expose the new static poster while it prepares.
            .opacity((activeResource == nil && !shouldHideStationaryVisual) ? 1 : 0)
            .transaction { $0.animation = nil }
            .overlay {
                if let resource = activeResource {
                    MotionArtworkFrameSurface(
                        resource: resource, isPlaying: isPlaying,
                        defersPlayback: isSettling && frameProcessor != nil
                            && fullscreenCoordinator?.isActive != true,
                        followsSong: followsSong, processor: frameProcessor,
                        firstFrame: preparedFrame(for: resource),
                        uncroppedFirstFrame: preparedUncroppedFrame(for: resource),
                        frameOpacity: shouldHideStationaryVisual ? 0 : frameOpacity,
                        displaysFrames: !suppressesVideoRendering,
                        keepsPlayingInHierarchy: fullscreenCoordinator != nil,
                        onUncroppedFrame: { uncropped in
                            fullscreenCoordinator?.publishFrame(uncropped, for: resource)
                        },
                        onFrame: onFrame, onFailure: { failedResource = resource }
                    )
                        .transition(.identity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onAppear {
                            fullscreenCoordinator?.registerActivePlayer(
                                for: resource,
                                seedFrame: preparedUncroppedFrame(for: resource) ?? preparedFrame(for: resource)
                            )
                        }
                        .onChange(of: resource) { oldValue, newValue in
                            fullscreenCoordinator?.unregisterActivePlayer(for: oldValue)
                            fullscreenCoordinator?.registerActivePlayer(
                                for: newValue,
                                seedFrame: preparedUncroppedFrame(for: newValue) ?? preparedFrame(for: newValue)
                            )
                        }
                        .onDisappear {
                            fullscreenCoordinator?.unregisterActivePlayer(for: resource)
                        }
                }
            }
            .onChange(of: resource, initial: true) { _, newValue in
                settleTask?.cancel()
                failedResource = nil
                guard newValue != nil, followsSong else {
                    isSettling = false
                    return
                }
                isSettling = true
                settleTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    isSettling = false
                }
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
                isSettling = false
            }
    }
}

/// Processing remains off the main thread and never encodes intermediate images.
nonisolated struct MotionArtworkFrameProcessor: @unchecked Sendable {
    let identity: String
    let process: @Sendable (CGImage) -> CGImage?
}

@MainActor
final class MotionArtworkFrameCapture {
    var image: CGImage?
    var resource: MotionArtworkResource?
}

private struct MotionArtworkFrameSurface: View {
    let resource: MotionArtworkResource
    let isPlaying: Bool
    let defersPlayback: Bool
    let followsSong: Bool
    let processor: MotionArtworkFrameProcessor?
    let firstFrame: CGImage?
    let uncroppedFirstFrame: CGImage?
    let frameOpacity: Double
    let displaysFrames: Bool
    let keepsPlayingInHierarchy: Bool
    let onUncroppedFrame: ((CGImage) -> Void)?
    let onFrame: ((CGImage) -> Void)?
    let onFailure: () -> Void
    @State private var frame: CGImage?
    @State private var latestCapture = MotionArtworkFrameCapture()

    init(resource: MotionArtworkResource, isPlaying: Bool, defersPlayback: Bool, followsSong: Bool,
         processor: MotionArtworkFrameProcessor?, firstFrame: CGImage?, uncroppedFirstFrame: CGImage? = nil,
         frameOpacity: Double, displaysFrames: Bool = true, keepsPlayingInHierarchy: Bool = false,
         onUncroppedFrame: ((CGImage) -> Void)? = nil,
         onFrame: ((CGImage) -> Void)?, onFailure: @escaping () -> Void) {
        self.resource = resource
        self.isPlaying = isPlaying
        self.defersPlayback = defersPlayback
        self.followsSong = followsSong
        self.processor = processor
        self.firstFrame = firstFrame
        self.uncroppedFirstFrame = uncroppedFirstFrame
        self.frameOpacity = frameOpacity
        self.displaysFrames = displaysFrames
        self.keepsPlayingInHierarchy = keepsPlayingInHierarchy
        self.onUncroppedFrame = onUncroppedFrame
        self.onFrame = onFrame
        self.onFailure = onFailure
        _frame = State(initialValue: processor == nil ? firstFrame : nil)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // This transparent AppKit leaf owns playback and visibility.
                // The resulting SwiftUI image participates in masks, transforms,
                // artistic frames and compositing groups on every skin.
                MotionArtworkPlayerSurface(
                    resource: resource, isPlaying: isPlaying, defersPlayback: defersPlayback,
                    followsSong: followsSong, processor: processor,
                    firstFrame: uncroppedFirstFrame ?? firstFrame,
                    keepsPlayingInHierarchy: keepsPlayingInHierarchy,
                    onFailure: onFailure
                ) { uncropped, raw, rendered in
                    latestCapture.resource = resource
                    latestCapture.image = rendered
                    onUncroppedFrame?(uncropped)
                    onFrame?(raw)
                    if displaysFrames { frame = rendered }
                }
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable().interpolation(.high).scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(frameOpacity)
                        .transaction { $0.animation = nil }
                }
            }
        }
        // Keep the last video frame until a frame of the new resource arrives.
        // The AppKit generation gate discards any late old-resource render.
        .onChange(of: displaysFrames) { _, displays in
            // A paused clip has no next frame to deliver; restore the exact
            // frame the fullscreen layer was showing.
            guard displays, let image = latestCapture.image else { return }
            frame = image
        }
    }
}

private struct MotionArtworkPlayerSurface: NSViewRepresentable {
    let resource: MotionArtworkResource
    let isPlaying: Bool
    let defersPlayback: Bool
    let followsSong: Bool
    let processor: MotionArtworkFrameProcessor?
    let firstFrame: CGImage?
    var keepsPlayingInHierarchy: Bool = false
    let onFailure: () -> Void
    let onFrame: (CGImage, CGImage, CGImage) -> Void

    func makeNSView(context: Context) -> MotionArtworkPlayerView { MotionArtworkPlayerView() }

    func updateNSView(_ nsView: MotionArtworkPlayerView, context: Context) {
        nsView.update(resource: resource, isPlaying: isPlaying, defersPlayback: defersPlayback,
                      followsSong: followsSong, processor: processor, firstFrame: firstFrame,
                      keepsPlayingInHierarchy: keepsPlayingInHierarchy,
                      onFailure: onFailure, onFrame: onFrame)
    }

    static func dismantleNSView(_ nsView: MotionArtworkPlayerView, coordinator: ()) { nsView.releaseResources() }
}

struct MotionArtworkFrameFlightGate {
    private(set) var activeRequestID: UUID?

    var isInFlight: Bool { activeRequestID != nil }

    mutating func begin() -> UUID? {
        guard activeRequestID == nil else { return nil }
        let requestID = UUID()
        activeRequestID = requestID
        return requestID
    }

    mutating func finish(_ requestID: UUID) -> Bool {
        guard activeRequestID == requestID else { return false }
        activeRequestID = nil
        return true
    }
}

/// The playing song's audible position and length, installed by the playback
/// session. A video about as long as the song is a music video: it follows
/// the song's timeline instead of looping.
@MainActor
final class MotionArtworkSongClock {
    static let shared = MotionArtworkSongClock()

    var source: (() -> (time: Double, duration: Double)?)?
    var localTrack: (() -> Track?)?
    var alignment: MotionAudioAlignmentCoordinator?

    private init() {}

    var time: Double? { source?()?.time }
    var songDuration: Double? { source?()?.duration }

    func offset(for resource: MotionArtworkResource) -> Double? {
        guard let track = localTrack?() else { return nil }
        return alignment?.offset(track: track, video: resource.url)
    }

    func isMusicVideo(duration video: Double) -> Bool {
        guard let song = songDuration else { return false }
        return MotionAudioAligner.isMusicVideo(songDuration: song, videoDuration: video)
    }
}

/// AVFoundation applies MP4 edit lists, so its native timeline can differ
/// from the raw fragment timestamps recorded by the download helper.
nonisolated enum MotionArtworkLoopRange {
    static func load(asset: AVURLAsset, fallback: CMTimeRange) async -> CMTimeRange? {
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        let trackRange: CMTimeRange?
        if let track = tracks?.first { trackRange = try? await track.load(.timeRange) }
        else { trackRange = nil }
        let duration = try? await asset.load(.duration)
        let assetRange = duration.flatMap { value -> CMTimeRange? in
            let range = CMTimeRange(start: .zero, duration: value)
            return valid(range) ? range : nil
        }
        if let trackRange, valid(trackRange) {
            let playable = assetRange.map { CMTimeRangeGetIntersection(trackRange, otherRange: $0) } ?? trackRange
            if valid(playable) { return playable }
        }
        if let assetRange { return assetRange }
        return valid(fallback) ? fallback : nil
    }

    private static func valid(_ range: CMTimeRange) -> Bool {
        range.isValid && range.start.seconds.isFinite && range.start.seconds >= 0
            && range.duration.seconds.isFinite && range.duration.seconds > 0
    }
}

private final class MotionArtworkPlayerView: NSView {
    private var videoOutput: AVPlayerItemVideoOutput?
    private var frameTimer: Timer?
    private var frameTask: Task<Void, Never>?
    private var frameFlightGate = MotionArtworkFrameFlightGate()
    private var pendingProcessorRedraw: CGImage?
    private var frameGeneration = UUID()
    private var preferredTransform = CGAffineTransform.identity
    private var latestUncroppedFrame: CGImage?
    private var latestRawFrame: CGImage?
    private var frameProcessor: MotionArtworkFrameProcessor?
    private var onFrame: ((CGImage, CGImage, CGImage) -> Void)?
    private var onFailure: (() -> Void)?
    private var keepsPlayingInHierarchy = false
    private nonisolated static let imageContext = CIContext(options: [.cacheIntermediates: false])

    /// Color space CoreVideo attached while decoding; untagged streams are read as Rec.709.
    private nonisolated static func frameColorSpace(of buffer: CVPixelBuffer) -> CGColorSpace {
        CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue()
            ?? CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    /// A music video plays once, on the song's timeline, instead of looping.
    private var isMusicVideo = false
    private var lastSongOffset: Double?
    private var followsSong = true
    private var videoRange = CMTimeRange.invalid
    private var lastTimelineCheck: CFTimeInterval = 0
    private var isSeeking = false
    private var preparationTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var resource: MotionArtworkResource?
    private var wantsPlayback = false
    private var defersPlayback = false
    private var failedResource: MotionArtworkResource?
    private var itemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private weak var observedWindow: NSWindow?
    private var sourceFrameRate: Float = 0
    private var deliveryStarted: CFTimeInterval = 0
    private var deliveredFrames = 0
    private var processingMilliseconds = 0.0
    private var longestProcessingMilliseconds = 0.0
    private var captureMillisecondsTotal = 0.0
    private var longestCaptureMilliseconds = 0.0
    private var handoffMillisecondsTotal = 0.0
    private var longestHandoffMilliseconds = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        preparationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(resource: MotionArtworkResource, isPlaying: Bool, defersPlayback: Bool, followsSong: Bool,
                processor: MotionArtworkFrameProcessor?, firstFrame: CGImage?,
                keepsPlayingInHierarchy: Bool = false,
                onFailure: @escaping () -> Void, onFrame: @escaping (CGImage, CGImage, CGImage) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.followsSong = followsSong
        self.defersPlayback = defersPlayback
        self.keepsPlayingInHierarchy = keepsPlayingInHierarchy
        let processorChanged = frameProcessor?.identity != processor?.identity
        if processorChanged {
            frameGeneration = UUID()
            frameTask?.cancel()
        }
        frameProcessor = processor
        if self.resource != resource {
            stopPlayer()
            self.resource = resource
            latestUncroppedFrame = nil
            latestRawFrame = nil
            failedResource = nil
        }
        if wantsPlayback && !isPlaying {
            // A transition freezes the frame already on screen. Discard an
            // unfinished video frame without losing that displayed source;
            // a changed processor below may still redraw it while paused.
            frameGeneration = UUID()
            frameTask?.cancel()
            resetFrameMeasurements()
        }
        wantsPlayback = isPlaying
        if latestRawFrame == nil, let firstFrame {
            // The seed is already oriented and cropped. It uses the same
            // one-flight processing gate and skin processor as live frames.
            processFrame(.image(firstFrame))
        }
        reconcilePlayback()
        if processorChanged, let latest = latestUncroppedFrame ?? latestRawFrame { processFrame(.image(latest)) }
    }

    override func layout() {
        super.layout()
        reconcilePlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installVisibilityObservers()
        reconcilePlayback()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reconcilePlayback()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcilePlayback()
    }

    private var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
            && (keepsPlayingInHierarchy || (!isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty))
    }

    private func reconcilePlayback() {
        guard isVisible else {
            stopPlayer()
            return
        }
        if player == nil { preparePlayer() }
        guard (wantsPlayback && !defersPlayback) || latestRawFrame == nil else {
            player?.pause()
            frameTimer?.invalidate()
            frameTimer = nil
            return
        }
        player?.play()
        syncToSong(force: false)
        startFrameTimer()
    }

    private func startFrameTimer() {
        guard frameTimer == nil, player != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func readFrame() {
        checkSongTimeline()
        guard !isSeeking, frameTask == nil, let output = videoOutput, let player else { return }
        let captureStarted = CACurrentMediaTime()
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        let captureMilliseconds = (CACurrentMediaTime() - captureStarted) * 1000
        processFrame(.buffer(buffer, captureMilliseconds: captureMilliseconds))
    }

    private func processFrame(_ input: MotionArtworkFrameInput) {
        guard !frameFlightGate.isInFlight else {
            if case .image(let image) = input {
                pendingProcessorRedraw = image
            }
            return
        }
        guard let requestID = frameFlightGate.begin() else { return }
        let processor = frameProcessor
        let transform = preferredTransform
        let generation = frameGeneration
        let requestStartedAt = CACurrentMediaTime()
        // One in-flight render bounds work without lowering source resolution.
        let operation = Task.detached(priority: .userInitiated) { () -> MotionArtworkRenderedFrame? in
            autoreleasepool {
                let started = CACurrentMediaTime()
                guard !Task.isCancelled else { return nil }
                // Keep the full oriented frame for fullscreen video playback while
                // providing the center-square crop to square cover skins and processors.
                let uncropped: CGImage
                let square: CGImage
                switch input {
                case .buffer(let buffer, _):
                    let image = MotionArtworkFrameOrientation.apply(CIImage(cvPixelBuffer: buffer), preferredTransform: transform)
                    // Keep the stream's own color space on the frame, as the
                    // first-frame poster does. An untagged image skips ColorSync,
                    // so wide-gamut displays would oversaturate Rec.709 video.
                    let frameSpace = Self.frameColorSpace(of: buffer)
                    guard !Task.isCancelled,
                          let decoded = Self.imageContext.createCGImage(
                            image,
                            from: image.extent,
                            format: .BGRA8,
                            colorSpace: frameSpace
                          ) else { return nil }
                    uncropped = decoded
                    square = MotionArtworkFrameGeometry.centerSquareCrop(decoded)
                case .image(let image):
                    uncropped = image
                    square = MotionArtworkFrameGeometry.centerSquareCrop(image)
                }
                guard !Task.isCancelled else { return nil }
                let result = processor == nil ? square : processor?.process(square)
                guard !Task.isCancelled, let rendered = result else { return nil }
                return MotionArtworkRenderedFrame(
                    uncropped: uncropped, raw: square, rendered: rendered,
                    processingMilliseconds: (CACurrentMediaTime() - started) * 1000
                )
            }
        }
        frameTask = Task { @MainActor [weak self] in
            let frame = await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
            guard let self, self.frameFlightGate.finish(requestID) else { return }
            self.frameTask = nil
            let pendingRedraw = self.pendingProcessorRedraw
            self.pendingProcessorRedraw = nil
            if self.frameGeneration == generation, !Task.isCancelled, let frame {
                let isFirstFrame = self.latestRawFrame == nil
                self.latestUncroppedFrame = frame.uncropped
                self.latestRawFrame = frame.raw
                self.onFrame?(frame.uncropped, frame.raw, frame.rendered)
                if isFirstFrame { self.reconcilePlayback() }
                if case .buffer(_, let captureMilliseconds) = input, self.wantsPlayback {
                    let handoffMilliseconds = max(
                        0,
                        (CACurrentMediaTime() - requestStartedAt) * 1000 - frame.processingMilliseconds
                    )
                    self.recordFrameDelivery(
                        captureMilliseconds: captureMilliseconds,
                        processingMilliseconds: frame.processingMilliseconds,
                        handoffMilliseconds: handoffMilliseconds
                    )
                }
            }
            if let pendingRedraw {
                self.processFrame(.image(pendingRedraw))
            }
        }
    }

    private func resetFrameMeasurements() {
        deliveryStarted = 0
        deliveredFrames = 0
        processingMilliseconds = 0
        longestProcessingMilliseconds = 0
        captureMillisecondsTotal = 0
        longestCaptureMilliseconds = 0
        handoffMillisecondsTotal = 0
        longestHandoffMilliseconds = 0
    }

    private func recordFrameDelivery(
        captureMilliseconds captureElapsed: Double,
        processingMilliseconds processingElapsed: Double,
        handoffMilliseconds handoffElapsed: Double
    ) {
        let now = CACurrentMediaTime()
        if deliveryStarted == 0 { deliveryStarted = now }
        deliveredFrames += 1
        processingMilliseconds += processingElapsed
        longestProcessingMilliseconds = max(longestProcessingMilliseconds, processingElapsed)
        captureMillisecondsTotal += captureElapsed
        longestCaptureMilliseconds = max(longestCaptureMilliseconds, captureElapsed)
        handoffMillisecondsTotal += handoffElapsed
        longestHandoffMilliseconds = max(longestHandoffMilliseconds, handoffElapsed)
        let interval = now - deliveryStarted
        guard interval >= 2 else { return }
        DebugUIHooks.record(String(
            format: "motion-delivery sourceFPS=%.2f deliveredFPS=%.2f frames=%d mean=%.1fms max=%.1fms panorama=%@ captureMean=%.1fms captureMax=%.1fms handoffMean=%.1fms handoffMax=%.1fms",
            Double(sourceFrameRate), Double(deliveredFrames - 1) / interval,
            deliveredFrames, processingMilliseconds / Double(deliveredFrames),
            longestProcessingMilliseconds, frameProcessor == nil ? "false" : "true",
            captureMillisecondsTotal / Double(deliveredFrames), longestCaptureMilliseconds,
            handoffMillisecondsTotal / Double(deliveredFrames), longestHandoffMilliseconds
        ))
        resetFrameMeasurements()
    }

    private func preparePlayer() {
        guard preparationTask == nil, let resource,
              resource != failedResource, resource.url.isFileURL else { return }
        let id = UUID()
        preparationID = id
        let asset = AVURLAsset(url: resource.url)
        let fallback = CMTimeRange(
            start: CMTime(seconds: resource.startTime.isFinite ? resource.startTime : -1, preferredTimescale: 600),
            duration: CMTime(seconds: resource.duration.isFinite ? resource.duration : 0, preferredTimescale: 600)
        )
        preparationTask = Task { @MainActor [weak self] in
            let range = await MotionArtworkLoopRange.load(asset: asset, fallback: fallback)
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            let transform = try? await tracks?.first?.load(.preferredTransform)
            let nominalFrameRate = try? await tracks?.first?.load(.nominalFrameRate)
            guard !Task.isCancelled, let self, self.preparationID == id,
                  self.resource == resource else { return }
            self.preparationTask = nil
            self.preparationID = nil
            guard self.isVisible else { return }
            guard let range else {
                self.failedResource = resource
                self.onFailure?()
                return
            }
            self.preferredTransform = transform ?? .identity
            self.sourceFrameRate = nominalFrameRate ?? 0
            self.installPlayer(asset: asset, range: range)
        }
    }

    private func installPlayer(asset: AVURLAsset, range: CMTimeRange) {
        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        videoRange = range
        isMusicVideo = playsAsMusicVideo(range)
        if isMusicVideo {
            player.actionAtItemEnd = .pause
            player.insert(item, after: nil)
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
            // Prepare each queued copy before it becomes current, so the first
            // frame of a loop does not wait for a new output to be attached.
            for queuedItem in looper?.loopingPlayerItems ?? [] {
                _ = videoOutput(for: queuedItem)
            }
        }
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self, weak player] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.observeCurrentItem()
            }
        }
        syncToSong(force: true)
        reconcilePlayback()
    }

    /// Checked a few times a second: a song change can turn a shared album
    /// video into a music video or back, and a music video follows seeks.
    private func checkSongTimeline() {
        let now = CACurrentMediaTime()
        guard player != nil, now - lastTimelineCheck >= 0.25 else { return }
        lastTimelineCheck = now
        if playsAsMusicVideo(videoRange) != isMusicVideo {
            stopPlayer()
            reconcilePlayback()
            return
        }
        syncToSong(force: false)
    }

    private func playsAsMusicVideo(_ range: CMTimeRange) -> Bool {
        followsSong && MotionArtworkSongClock.shared.isMusicVideo(duration: range.duration.seconds)
    }

    private func syncToSong(force: Bool) {
        guard isMusicVideo, !isSeeking, let player, let songTime = MotionArtworkSongClock.shared.time else { return }
        let offset = resource.flatMap { MotionArtworkSongClock.shared.offset(for: $0) }
        let offsetChanged = offset != lastSongOffset
        lastSongOffset = offset
        let target = songTime + (offset ?? videoRange.start.seconds)
        let end = videoRange.end.seconds
        // Past the video's end the last frame holds until the song seeks back.
        let clamped = max(videoRange.start.seconds, min(target, end - 0.05))
        let current = player.currentTime().seconds
        if target < videoRange.start.seconds || target >= end - 0.05 {
            if player.rate != 0 { player.pause() }
        } else if wantsPlayback, !defersPlayback, player.rate == 0 {
            player.play()
        }
        guard force || offsetChanged || !current.isFinite || abs(current - clamped) > (offset == nil ? 0.2 : 0.08) else { return }
        isSeeking = true
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.isSeeking = false
            }
        }
    }

    private func observeCurrentItem() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        guard let item = player?.currentItem else {
            videoOutput = nil
            return
        }
        videoOutput = videoOutput(for: item)
        DebugUIHooks.record("motion-loop outputs=\(item.outputs.count)")
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player?.currentItem === item, item.status == .failed else { return }
                self.failedResource = self.resource
                self.stopPlayer()
                self.onFailure?()
            }
        }
    }

    private func videoOutput(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let output = item.outputs.first(where: { $0 is AVPlayerItemVideoOutput }) as? AVPlayerItemVideoOutput {
            return output
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        return output
    }

    private func stopPlayer() {
        resetFrameMeasurements()
        preparationTask?.cancel()
        preparationTask = nil
        preparationID = nil
        frameGeneration = UUID()
        frameTask?.cancel()
        pendingProcessorRedraw = nil
        frameTimer?.invalidate()
        frameTimer = nil
        videoOutput = nil
        itemObservation?.invalidate()
        itemObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        isMusicVideo = false
        lastSongOffset = nil
        isSeeking = false
    }

    @objc private func visibilityDidChange(_ notification: Notification) {
        reconcilePlayback()
    }

    private func installVisibilityObservers() {
        guard observedWindow !== window else { return }
        NotificationCenter.default.removeObserver(self)
        observedWindow = window
        guard let window else { return }
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(visibilityDidChange(_:)), name: name, object: window
            )
        }
    }

    func releaseResources() {
        wantsPlayback = false
        resource = nil
        latestUncroppedFrame = nil
        latestRawFrame = nil
        onFrame = nil
        onFailure = nil
        stopPlayer()
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
    }
}

private nonisolated enum MotionArtworkFrameInput: @unchecked Sendable {
    case buffer(CVPixelBuffer, captureMilliseconds: Double)
    case image(CGImage)
}
private nonisolated struct MotionArtworkRenderedFrame: @unchecked Sendable {
    let uncropped: CGImage
    let raw: CGImage
    let rendered: CGImage
    let processingMilliseconds: Double
}

nonisolated enum MotionArtworkFrameOrientation {
    static func apply(_ image: CIImage, preferredTransform: CGAffineTransform) -> CIImage {
        let oriented = image.transformed(by: preferredTransform)
        return oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
    }
}

nonisolated enum MotionArtworkFrameGeometry {
    /// Crop in CI coordinates before creating a full-size CGImage. The source
    /// crop uses top-origin pixel rows; Core Image extents use a bottom origin.
    static func centerSquareCrop(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return image }
        let width = Int(extent.width.rounded(.down))
        let height = Int(extent.height.rounded(.down))
        let side = min(width, height)
        guard side > 0 else { return image }
        let leftOffset = (width - side) / 2
        let topOffset = (height - side) / 2
        let bottomOffset = height - side - topOffset
        let crop = CGRect(
            x: extent.minX + CGFloat(leftOffset),
            y: extent.minY + CGFloat(bottomOffset),
            width: CGFloat(side),
            height: CGFloat(side)
        )
        return image.cropped(to: crop)
    }

    static func centerSquareCrop(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width != height else { return image }
        let side = min(width, height)
        let rect = CGRect(
            x: (width - side) / 2,
            y: (height - side) / 2,
            width: side,
            height: side
        )
        return image.cropping(to: rect) ?? image
    }
}

// MARK: - Dynamic Cover Fullscreen Video Mode

enum FullscreenVideoCoordinateSpace {
    nonisolated static let name = "kmgccc.fullscreenPlayerViewport"
}

enum MotionArtworkFullscreenHandoffStyle: Equatable {
    case directLiftOff
    case maskedCrossfade
}

struct MotionArtworkCoverSourceGeometry: Equatable {
    var frame: CGRect
    var cornerRadius: CGFloat
    var handoffStyle: MotionArtworkFullscreenHandoffStyle
}

@Observable
@MainActor
final class MotionArtworkFullscreenCoordinator {
    enum Phase: Equatable {
        case idle
        case entering
        case active
        case exiting
    }

    private(set) var phase: Phase = .idle
    private(set) var sourceGeometry: MotionArtworkCoverSourceGeometry?
    /// Pixel dimensions of the playing video. It is the only per-resource
    /// value the SwiftUI overlay reads, and it changes at most once per clip.
    private(set) var mediaSize: CGSize = .zero
    private(set) var latestFrameResource: MotionArtworkResource?
    private(set) var fallbackPoster: NSImage?
    private(set) var activeResourcePlayerCounts: [MotionArtworkResource: Int] = [:]

    /// Frames are delivered straight to the overlay's CALayer. Keeping them
    /// out of Observation avoids one SwiftUI update per video frame.
    @ObservationIgnored private(set) var latestUncroppedFrame: CGImage?
    @ObservationIgnored private var frameSinkID: UUID?
    @ObservationIgnored private var frameSink: ((CGImage) -> Void)?
    @ObservationIgnored private var phaseTask: Task<Void, Never>?

    var isActive: Bool { phase != .idle }

    func canEnter(
        for resource: MotionArtworkResource?,
        motionArtworkEnabled: Bool = true,
        motionPolicy: MotionPolicy
    ) -> Bool {
        guard motionArtworkEnabled,
              motionPolicy == .full,
              let resource,
              resource.url.isFileURL else {
            return false
        }
        return true
    }

    func shouldHideStationaryCoverVisual(for resource: MotionArtworkResource?) -> Bool {
        guard phase != .idle,
              sourceGeometry?.handoffStyle == .directLiftOff,
              let resource,
              latestFrameResource == resource else {
            return false
        }
        return true
    }

    func registerActivePlayer(for resource: MotionArtworkResource, seedFrame: CGImage?) {
        activeResourcePlayerCounts[resource, default: 0] += 1
        if let seedFrame, latestFrameResource != resource {
            publishFrame(seedFrame, for: resource)
        }
    }

    func unregisterActivePlayer(for resource: MotionArtworkResource?) {
        guard let resource else { return }
        let next = (activeResourcePlayerCounts[resource] ?? 0) - 1
        if next <= 0 {
            activeResourcePlayerCounts.removeValue(forKey: resource)
        } else {
            activeResourcePlayerCounts[resource] = next
        }
    }

    var hasAnyActivePlayer: Bool {
        !activeResourcePlayerCounts.isEmpty
    }

    func publishFrame(_ frame: CGImage, for resource: MotionArtworkResource) {
        latestUncroppedFrame = frame
        if latestFrameResource != resource {
            latestFrameResource = resource
        }
        let size = CGSize(width: frame.width, height: frame.height)
        if mediaSize != size {
            mediaSize = size
        }
        frameSink?(frame)
    }

    func installFrameSink(
        id: UUID,
        sink: @escaping (CGImage) -> Void
    ) {
        frameSinkID = id
        frameSink = sink
        if let latestUncroppedFrame {
            sink(latestUncroppedFrame)
        }
    }

    func removeFrameSink(id: UUID) {
        guard frameSinkID == id else { return }
        frameSinkID = nil
        frameSink = nil
    }

    func updateSourceGeometry(_ geometry: MotionArtworkCoverSourceGeometry) {
        guard sourceGeometry != geometry else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            sourceGeometry = geometry
        }
    }

    func enter(
        resource: MotionArtworkResource?,
        fallbackPoster: NSImage?,
        motionArtworkEnabled: Bool = true,
        motionPolicy: MotionPolicy,
        motionTokens: MotionTokens
    ) {
        guard canEnter(
            for: resource,
            motionArtworkEnabled: motionArtworkEnabled,
            motionPolicy: motionPolicy
        ), phase == .idle else { return }

        phaseTask?.cancel()
        phaseTask = nil
        if let fallbackPoster {
            self.fallbackPoster = fallbackPoster
        }
        if latestFrameResource == resource, let frame = latestUncroppedFrame {
            let size = CGSize(width: frame.width, height: frame.height)
            if mediaSize != size {
                mediaSize = size
            }
        } else {
            // A frame from another resource says nothing about this clip's
            // aspect ratio or content; wait for the first current frame.
            mediaSize = .zero
            latestUncroppedFrame = nil
        }

        let spec = motionTokens[.emphasis]
        let delay = motionPolicy.visualCompletionDelay(for: spec)
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            phase = delay > 0 ? .entering : .active
        }

        guard delay > 0 else { return }
        phaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.15))
            guard !Task.isCancelled, let self, self.phase == .entering else { return }
            var finish = Transaction()
            finish.animation = nil
            withTransaction(finish) {
                self.phase = .active
            }
        }
    }

    func exit(motionPolicy: MotionPolicy, motionTokens: MotionTokens) {
        guard phase == .entering || phase == .active else { return }
        phaseTask?.cancel()
        phaseTask = nil

        let spec = motionTokens[.emphasis]
        let delay = motionPolicy.visualCompletionDelay(for: spec)
        if delay <= 0 {
            finishExit()
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            phase = .exiting
        }
        phaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.15))
            guard !Task.isCancelled, let self, self.phase == .exiting else { return }
            self.finishExit()
        }
    }

    private func finishExit() {
        guard phase == .entering || phase == .active || phase == .exiting else { return }
        phaseTask?.cancel()
        phaseTask = nil
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            phase = .idle
            fallbackPoster = nil
        }
    }

    func resetImmediately() {
        phaseTask?.cancel()
        phaseTask = nil
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            phase = .idle
            sourceGeometry = nil
            mediaSize = .zero
            latestUncroppedFrame = nil
            latestFrameResource = nil
            fallbackPoster = nil
        }
    }
}

extension EnvironmentValues {
    @Entry var motionArtworkFullscreenCoordinator: MotionArtworkFullscreenCoordinator? = nil
}

private nonisolated struct MotionArtworkFullscreenSourceProbe: Equatable, Sendable {
    var viewportFrame: CGRect
    var localSize: CGSize
}

struct MotionArtworkFullscreenSourceModifier: ViewModifier {
    let context: SkinContext
    var cornerRadius: CGFloat = 12
    var insetScale: CGFloat = 1.0
    var handoffStyle: MotionArtworkFullscreenHandoffStyle = .directLiftOff

    @Environment(\.motionArtworkFullscreenCoordinator) private var coordinator
    @State private var lastProbe: MotionArtworkFullscreenSourceProbe?

    private var hidesSourceVisual: Bool {
        // Keep the skin artwork (glow, frame, shell) under the growing video
        // during both handoffs. It is hidden only while the video owns the
        // screen, so no decoration pops at the moment the zoom begins.
        guard let coordinator, coordinator.isActive else { return false }
        return coordinator.phase == .active
    }

    func body(content: Content) -> some View {
        content
            .opacity(hidesSourceVisual ? 0 : 1)
            .onGeometryChange(for: MotionArtworkFullscreenSourceProbe.self) { proxy in
                MotionArtworkFullscreenSourceProbe(
                    viewportFrame: proxy.frame(in: .named(FullscreenVideoCoordinateSpace.name)),
                    localSize: proxy.size
                )
            } action: { probe in
                lastProbe = probe
                publishGeometry(probe)
            }
            .onChange(of: handoffStyle) { _, _ in
                if let lastProbe {
                    publishGeometry(lastProbe)
                }
            }
            .onChange(of: insetScale) { _, _ in
                if let lastProbe {
                    publishGeometry(lastProbe)
                }
            }
    }

    private func publishGeometry(_ probe: MotionArtworkFullscreenSourceProbe) {
        guard let coordinator,
              probe.viewportFrame.width > 1,
              probe.viewportFrame.height > 1 else {
            return
        }
        let clampedScale = max(0.1, min(1.5, insetScale))
        let insetWidth = probe.viewportFrame.width * clampedScale
        let insetHeight = probe.viewportFrame.height * clampedScale
        let resolvedFrame = CGRect(
            x: probe.viewportFrame.midX - insetWidth * 0.5,
            y: probe.viewportFrame.midY - insetHeight * 0.5,
            width: insetWidth,
            height: insetHeight
        )
        let scaleFactor = probe.localSize.width > 1
            ? (probe.viewportFrame.width / probe.localSize.width)
            : 1.0
        let resolvedCornerRadius = max(0, cornerRadius * scaleFactor)
        coordinator.updateSourceGeometry(
            MotionArtworkCoverSourceGeometry(
                frame: resolvedFrame,
                cornerRadius: resolvedCornerRadius,
                handoffStyle: handoffStyle
            )
        )
    }
}

extension View {
    func motionArtworkFullscreenSource(
        context: SkinContext,
        cornerRadius: CGFloat = 12,
        insetScale: CGFloat = 1.0,
        handoffStyle: MotionArtworkFullscreenHandoffStyle = .directLiftOff
    ) -> some View {
        modifier(
            MotionArtworkFullscreenSourceModifier(
                context: context,
                cornerRadius: cornerRadius,
                insetScale: insetScale,
                handoffStyle: handoffStyle
            )
        )
    }
}

struct FullscreenMotionArtworkVideoOverlay: View {
    let coordinator: MotionArtworkFullscreenCoordinator
    let resource: MotionArtworkResource?
    let isPlaying: Bool
    let fallbackPoster: NSImage?
    let viewportSize: CGSize
    let fallbackSourceRect: CGRect
    let motionPolicy: MotionPolicy
    let motionTokens: MotionTokens

    init(
        coordinator: MotionArtworkFullscreenCoordinator,
        resource: MotionArtworkResource?,
        isPlaying: Bool,
        fallbackPoster: NSImage? = nil,
        viewportSize: CGSize,
        fallbackSourceRect: CGRect = .zero,
        motionPolicy: MotionPolicy,
        motionTokens: MotionTokens
    ) {
        self.coordinator = coordinator
        self.resource = resource
        self.isPlaying = isPlaying
        self.fallbackPoster = fallbackPoster
        self.viewportSize = viewportSize
        self.fallbackSourceRect = fallbackSourceRect
        self.motionPolicy = motionPolicy
        self.motionTokens = motionTokens
    }

    @Environment(LibraryCacheServices.self) private var cacheServices
    @AppStorage(AppSettings.motionArtworkEnabledDefaultsKey) private var motionArtworkEnabled = true

    private var activeResource: MotionArtworkResource? {
        guard motionArtworkEnabled,
              motionPolicy == .full,
              let resource,
              resource.url.isFileURL else {
            return nil
        }
        return resource
    }

    private var needsStandaloneFeeder: Bool {
        guard activeResource != nil else { return false }
        return !coordinator.hasAnyActivePlayer
    }

    private var resolvedSourceGeometry: MotionArtworkCoverSourceGeometry? {
        if let geometry = coordinator.sourceGeometry,
           geometry.frame.width > 1,
           geometry.frame.height > 1 {
            return geometry
        }
        if fallbackSourceRect.width > 1, fallbackSourceRect.height > 1 {
            return MotionArtworkCoverSourceGeometry(
                frame: fallbackSourceRect,
                cornerRadius: 12,
                handoffStyle: .directLiftOff
            )
        }
        let side = max(1, min(viewportSize.width, viewportSize.height) * 0.5)
        guard viewportSize.width > 1, viewportSize.height > 1 else { return nil }
        return MotionArtworkCoverSourceGeometry(
            frame: CGRect(
                x: (viewportSize.width - side) * 0.5,
                y: (viewportSize.height - side) * 0.5,
                width: side,
                height: side
            ),
            cornerRadius: 12,
            handoffStyle: .directLiftOff
        )
    }

    private var targetRect: CGRect {
        let mediaSize: CGSize = {
            if coordinator.mediaSize.width > 0, coordinator.mediaSize.height > 0 {
                return coordinator.mediaSize
            }
            if let poster = fallbackPoster ?? coordinator.fallbackPoster,
               poster.size.width > 0, poster.size.height > 0 {
                return poster.size
            }
            return CGSize(width: 1, height: 1)
        }()
        return Self.fittedVideoRect(in: viewportSize, mediaSize: mediaSize)
    }

    var body: some View {
        ZStack {
            if let activeResource, needsStandaloneFeeder {
                MotionArtworkPlayerSurface(
                    resource: activeResource,
                    isPlaying: isPlaying,
                    defersPlayback: false,
                    followsSong: true,
                    processor: nil,
                    firstFrame: cacheServices.motionArtworkFirstFrameCache.cachedUncroppedFrame(for: activeResource)
                        ?? cacheServices.motionArtworkFirstFrameCache.cachedFrame(for: activeResource),
                    keepsPlayingInHierarchy: true,
                    onFailure: {},
                    onFrame: { uncropped, _, _ in
                        coordinator.publishFrame(uncropped, for: activeResource)
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            if coordinator.phase != .idle, activeResource != nil, let source = resolvedSourceGeometry {
                MotionArtworkFullscreenVideoLayer(
                    coordinator: coordinator,
                    viewportSize: viewportSize,
                    sourceRect: source.frame,
                    sourceCornerRadius: source.cornerRadius,
                    targetRect: targetRect,
                    handoffStyle: source.handoffStyle,
                    phase: coordinator.phase,
                    motionPolicy: motionPolicy,
                    motionTokens: motionTokens
                )
                .frame(width: viewportSize.width, height: viewportSize.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                if coordinator.phase == .active {
                    Color.clear
                        .frame(width: viewportSize.width, height: viewportSize.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            coordinator.exit(motionPolicy: motionPolicy, motionTokens: motionTokens)
                        }
                        .accessibilityLabel("退出视频全屏")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
    }

    static func fittedVideoRect(in viewportSize: CGSize, mediaSize: CGSize) -> CGRect {
        guard viewportSize.width > 1, viewportSize.height > 1 else { return .zero }
        let aspect = (mediaSize.width > 0 && mediaSize.height > 0)
            ? (mediaSize.width / mediaSize.height)
            : 1.0
        let viewportAspect = viewportSize.width / viewportSize.height
        let width: CGFloat
        let height: CGFloat
        if aspect >= viewportAspect {
            width = viewportSize.width
            height = viewportSize.width / max(0.01, aspect)
        } else {
            height = viewportSize.height
            width = viewportSize.height * aspect
        }
        return CGRect(
            x: (viewportSize.width - width) * 0.5,
            y: (viewportSize.height - height) * 0.5,
            width: width,
            height: height
        )
    }
}

// MARK: - Fullscreen Video Layer

/// The video is drawn by one Core Animation layer instead of a SwiftUI image.
/// Layout stays fixed for the whole transition; only `bounds`, `position`,
/// `cornerRadius` and `opacity` are animated with MotionKit springs. Frames
/// keep arriving through the coordinator's sink while the layer moves, so the
/// clip never freezes mid-flight.
private struct MotionArtworkFullscreenVideoLayer: NSViewRepresentable {
    let coordinator: MotionArtworkFullscreenCoordinator
    let viewportSize: CGSize
    let sourceRect: CGRect
    let sourceCornerRadius: CGFloat
    let targetRect: CGRect
    let handoffStyle: MotionArtworkFullscreenHandoffStyle
    let phase: MotionArtworkFullscreenCoordinator.Phase
    let motionPolicy: MotionPolicy
    let motionTokens: MotionTokens

    func makeNSView(context: Context) -> MotionArtworkFullscreenVideoLayerView {
        MotionArtworkFullscreenVideoLayerView()
    }

    func updateNSView(_ nsView: MotionArtworkFullscreenVideoLayerView, context: Context) {
        let emphasis = motionTokens[.emphasis]
        nsView.apply(
            coordinator: coordinator,
            viewportSize: viewportSize,
            sourceRect: sourceRect,
            sourceCornerRadius: sourceCornerRadius,
            targetRect: targetRect,
            handoffStyle: handoffStyle,
            phase: phase,
            motionPolicy: motionPolicy,
            spec: emphasis,
            opacitySpec: motionTokens.phaseSpec(
                for: .emphasis,
                duration: emphasis.duration,
                bounce: 0
            )
        )
    }

    static func dismantleNSView(_ nsView: MotionArtworkFullscreenVideoLayerView, coordinator: ()) {
        nsView.detach()
    }
}

private final class MotionArtworkFullscreenVideoLayerView: NSView {
    private enum AnimationKey {
        static let bounds = "kmgccc.videoFullscreen.bounds"
        static let position = "kmgccc.videoFullscreen.position"
        static let cornerRadius = "kmgccc.videoFullscreen.cornerRadius"
        static let opacity = "kmgccc.videoFullscreen.opacity"
    }

    private let videoLayer = CALayer()
    private weak var coordinator: MotionArtworkFullscreenCoordinator?
    private var sinkID = UUID()
    private var configured = false
    private var appliedPhase: MotionArtworkFullscreenCoordinator.Phase = .idle
    private var viewportSize: CGSize = .zero
    private var sourceRect: CGRect = .zero
    private var sourceCornerRadius: CGFloat = 0
    private var targetRect: CGRect = .zero
    private var handoffStyle: MotionArtworkFullscreenHandoffStyle = .directLiftOff
    private var motionPolicy: MotionPolicy = .full
    private var motionSpec = MotionTokens.standard[.emphasis]
    private var opacitySpec = MotionTokens.standard.phaseSpec(
        for: .emphasis,
        duration: MotionTokens.standard[.emphasis].duration,
        bounce: 0
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting in AppKit's normal bottom-left geometry. SwiftUI's
        // top-left source and target rectangles are converted per frame.
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.masksToBounds = false

        videoLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        videoLayer.bounds = .zero
        videoLayer.contentsGravity = .resizeAspectFill
        videoLayer.masksToBounds = true
        videoLayer.cornerCurve = .continuous
        videoLayer.minificationFilter = .trilinear
        videoLayer.magnificationFilter = .linear
        videoLayer.allowsEdgeAntialiasing = true
        root.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard videoLayer.contentsScale != scale else { return }
        videoLayer.contentsScale = scale
    }

    func apply(
        coordinator: MotionArtworkFullscreenCoordinator,
        viewportSize: CGSize,
        sourceRect: CGRect,
        sourceCornerRadius: CGFloat,
        targetRect: CGRect,
        handoffStyle: MotionArtworkFullscreenHandoffStyle,
        phase: MotionArtworkFullscreenCoordinator.Phase,
        motionPolicy: MotionPolicy,
        spec: MotionSpec,
        opacitySpec: MotionSpec
    ) {
        if self.coordinator !== coordinator {
            self.coordinator?.removeFrameSink(id: sinkID)
            self.coordinator = coordinator
            sinkID = UUID()
            coordinator.installFrameSink(id: sinkID) { [weak self] image in
                self?.setImage(image)
            }
        }

        let viewportChanged = self.viewportSize != viewportSize
        let targetChanged = self.targetRect != targetRect
        let sourceChanged = self.sourceRect != sourceRect

        self.viewportSize = viewportSize
        self.sourceRect = sourceRect
        self.sourceCornerRadius = sourceCornerRadius
        self.targetRect = targetRect
        self.handoffStyle = handoffStyle
        self.motionPolicy = motionPolicy
        motionSpec = spec
        self.opacitySpec = opacitySpec

        guard !configured else {
            if phase != appliedPhase {
                appliedPhase = phase
                switch phase {
                case .entering:
                    setFrame(sourceRect, cornerRadius: sourceCornerRadius, opacity: startOpacity)
                    animate(to: targetRect, cornerRadius: 0, opacity: 1)
                case .active:
                    // A menu-triggered enter can report active before the
                    // spring has physically settled. Let the running spring
                    // finish instead of snapping it to its endpoint.
                    if videoLayer.animation(forKey: AnimationKey.bounds) == nil {
                        setFrame(targetRect, cornerRadius: 0, opacity: 1)
                    }
                case .exiting:
                    animate(to: sourceRect, cornerRadius: sourceCornerRadius, opacity: endOpacity)
                case .idle:
                    break
                }
                return
            }

            switch phase {
            case .active:
                if viewportChanged || targetChanged,
                   videoLayer.animation(forKey: AnimationKey.bounds) == nil {
                    setFrame(targetRect, cornerRadius: 0, opacity: 1)
                }
            case .entering:
                if targetChanged {
                    animate(to: targetRect, cornerRadius: 0, opacity: 1)
                }
            case .exiting:
                if sourceChanged || viewportChanged {
                    animate(to: sourceRect, cornerRadius: sourceCornerRadius, opacity: endOpacity)
                }
            case .idle:
                break
            }
            return
        }

        configured = true
        appliedPhase = phase
        switch phase {
        case .entering:
            setFrame(sourceRect, cornerRadius: sourceCornerRadius, opacity: startOpacity)
            animate(to: targetRect, cornerRadius: 0, opacity: 1, fromSource: true)
        case .active:
            setFrame(targetRect, cornerRadius: 0, opacity: 1)
        case .exiting:
            setFrame(sourceRect, cornerRadius: sourceCornerRadius, opacity: endOpacity)
        case .idle:
            break
        }
    }

    func detach() {
        coordinator?.removeFrameSink(id: sinkID)
        coordinator = nil
        videoLayer.removeAllAnimations()
        videoLayer.contents = nil
    }

    private var startOpacity: Float {
        handoffStyle == .maskedCrossfade ? 0 : 1
    }

    private var endOpacity: Float {
        handoffStyle == .maskedCrossfade ? 0 : 1
    }

    private func setImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = image
        CATransaction.commit()
    }

    private func setFrame(_ rect: CGRect, cornerRadius: CGFloat, opacity: Float) {
        let layerFrame = layerRect(for: rect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.removeAllAnimations()
        videoLayer.bounds = CGRect(origin: .zero, size: layerFrame.size)
        videoLayer.position = CGPoint(x: layerFrame.midX, y: layerFrame.midY)
        videoLayer.cornerRadius = cornerRadius
        videoLayer.opacity = opacity
        CATransaction.commit()
    }

    /// SwiftUI source and target rectangles use a top-left origin; the layer
    /// tree uses AppKit's bottom-left origin.
    private func layerRect(for rect: CGRect) -> CGRect {
        let height = viewportSize.height > 1 ? viewportSize.height : bounds.height
        return CGRect(
            x: rect.minX,
            y: height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func animate(
        to target: CGRect,
        cornerRadius: CGFloat,
        opacity: Float,
        fromSource: Bool = false
    ) {
        let current = fromSource ? nil : videoLayer.presentation()
        let fromRect: CGRect
        let fromCornerRadius: CGFloat
        let fromOpacity: Float
        if let current {
            let size = current.bounds.size
            fromRect = CGRect(
                x: current.position.x - size.width * 0.5,
                y: current.position.y - size.height * 0.5,
                width: size.width,
                height: size.height
            )
            fromCornerRadius = current.cornerRadius
            fromOpacity = current.opacity
        } else {
            fromRect = layerRect(for: sourceRect)
            fromCornerRadius = sourceCornerRadius
            fromOpacity = startOpacity
        }

        guard motionPolicy.resolve(motionSpec) != nil else {
            setFrame(target, cornerRadius: cornerRadius, opacity: opacity)
            return
        }

        videoLayer.removeAllAnimations()
        let targetLayerRect = layerRect(for: target)
        let targetBounds = CGRect(origin: .zero, size: targetLayerRect.size)
        let fromBounds = CGRect(origin: .zero, size: fromRect.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.bounds = targetBounds
        videoLayer.position = CGPoint(x: targetLayerRect.midX, y: targetLayerRect.midY)
        videoLayer.cornerRadius = cornerRadius
        videoLayer.opacity = opacity
        addSpring(
            keyPath: "bounds",
            from: NSValue(rect: fromBounds),
            to: NSValue(rect: targetBounds),
            key: AnimationKey.bounds,
            spec: motionSpec
        )
        addSpring(
            keyPath: "position",
            from: NSValue(point: CGPoint(x: fromRect.midX, y: fromRect.midY)),
            to: NSValue(point: CGPoint(x: targetLayerRect.midX, y: targetLayerRect.midY)),
            key: AnimationKey.position,
            spec: motionSpec
        )
        addSpring(
            keyPath: "cornerRadius",
            from: NSNumber(value: Double(fromCornerRadius)),
            to: NSNumber(value: Double(cornerRadius)),
            key: AnimationKey.cornerRadius,
            spec: motionSpec
        )
        if handoffStyle == .maskedCrossfade {
            addSpring(
                keyPath: "opacity",
                from: NSNumber(value: fromOpacity),
                to: NSNumber(value: opacity),
                key: AnimationKey.opacity,
                spec: opacitySpec
            )
        }
        CATransaction.commit()
    }

    private func addSpring(keyPath: String, from: Any, to: Any, key: String, spec: MotionSpec) {
        _ = MotionLayerAnimator.animate(
            layer: videoLayer,
            keyPath: keyPath,
            fromValue: from,
            toValue: to,
            spec: spec,
            policy: motionPolicy,
            animationKey: key
        )
    }
}
