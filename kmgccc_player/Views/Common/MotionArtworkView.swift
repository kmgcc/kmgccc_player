import AppKit
import AVFoundation
import CoreImage
import MotionKit
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
           (MotionArtworkSongClock.shared.time ?? 0) > 0.2 { return nil }
        return cacheServices.motionArtworkFirstFrameCache.cachedFrame(for: resource)
    }

    var body: some View {
        poster
            // A valid motion resource owns the picture from the start. Keep
            // layout, but never expose the new static poster while it prepares.
            .opacity(activeResource == nil ? 1 : 0)
            .transaction { $0.animation = nil }
            .overlay {
                if let resource = activeResource {
                    MotionArtworkFrameSurface(
                        resource: resource, isPlaying: isPlaying, defersPlayback: isSettling && frameProcessor != nil,
                        followsSong: followsSong, processor: frameProcessor,
                        firstFrame: preparedFrame(for: resource), frameOpacity: frameOpacity,
                        onFrame: onFrame, onFailure: { failedResource = resource }
                    )
                        .transition(.identity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
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
    let frameOpacity: Double
    let onFrame: ((CGImage) -> Void)?
    let onFailure: () -> Void
    @State private var frame: CGImage?

    init(resource: MotionArtworkResource, isPlaying: Bool, defersPlayback: Bool, followsSong: Bool,
         processor: MotionArtworkFrameProcessor?, firstFrame: CGImage?, frameOpacity: Double,
         onFrame: ((CGImage) -> Void)?, onFailure: @escaping () -> Void) {
        self.resource = resource
        self.isPlaying = isPlaying
        self.defersPlayback = defersPlayback
        self.followsSong = followsSong
        self.processor = processor
        self.firstFrame = firstFrame
        self.frameOpacity = frameOpacity
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
                MotionArtworkPlayerSurface(resource: resource, isPlaying: isPlaying, defersPlayback: defersPlayback,
                    followsSong: followsSong, processor: processor, firstFrame: firstFrame, onFailure: onFailure) { raw, rendered in
                    onFrame?(raw)
                    frame = rendered
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
    }
}

private struct MotionArtworkPlayerSurface: NSViewRepresentable {
    let resource: MotionArtworkResource
    let isPlaying: Bool
    let defersPlayback: Bool
    let followsSong: Bool
    let processor: MotionArtworkFrameProcessor?
    let firstFrame: CGImage?
    let onFailure: () -> Void
    let onFrame: (CGImage, CGImage) -> Void

    func makeNSView(context: Context) -> MotionArtworkPlayerView { MotionArtworkPlayerView() }

    func updateNSView(_ nsView: MotionArtworkPlayerView, context: Context) {
        nsView.update(resource: resource, isPlaying: isPlaying, defersPlayback: defersPlayback,
                      followsSong: followsSong, processor: processor, firstFrame: firstFrame,
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

    private init() {}

    var time: Double? { source?()?.time }
    var songDuration: Double? { source?()?.duration }

    func isMusicVideo(duration video: Double) -> Bool {
        guard let song = songDuration, song.isFinite, song >= 30,
              video.isFinite, video >= 60 else { return false }
        return abs(video - song) <= max(20, song * 0.2)
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
    private var latestRawFrame: CGImage?
    private var frameProcessor: MotionArtworkFrameProcessor?
    private var onFrame: ((CGImage, CGImage) -> Void)?
    private var onFailure: (() -> Void)?
    private nonisolated static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    /// A music video plays once, on the song's timeline, instead of looping.
    private var isMusicVideo = false
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
                onFailure: @escaping () -> Void, onFrame: @escaping (CGImage, CGImage) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.followsSong = followsSong
        self.defersPlayback = defersPlayback
        let processorChanged = frameProcessor?.identity != processor?.identity
        if processorChanged {
            frameGeneration = UUID()
            frameTask?.cancel()
        }
        frameProcessor = processor
        if self.resource != resource {
            stopPlayer()
            self.resource = resource
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
        if processorChanged, let latestRawFrame { processFrame(.image(latestRawFrame)) }
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
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
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
                // Motion artwork is displayed as a square cover everywhere.
                // Imported videos are not guaranteed to be square, and the
                // surrounding geometry assumes a square source.
                let square: CGImage
                switch input {
                case .buffer(let buffer, _):
                    let image = MotionArtworkFrameOrientation.apply(CIImage(cvPixelBuffer: buffer), preferredTransform: transform)
                    // Crop before rasterization so every frame avoids converting
                    // the offscreen bands of non-square video.
                    let croppedImage = MotionArtworkFrameGeometry.centerSquareCrop(image)
                    guard !Task.isCancelled,
                          let decoded = Self.imageContext.createCGImage(
                            croppedImage,
                            from: croppedImage.extent
                          ) else { return nil }
                    square = decoded
                case .image(let image):
                    square = MotionArtworkFrameGeometry.centerSquareCrop(image)
                }
                guard !Task.isCancelled else { return nil }
                let result = processor == nil ? square : processor?.process(square)
                guard !Task.isCancelled, let rendered = result else { return nil }
                return MotionArtworkRenderedFrame(
                    raw: square, rendered: rendered,
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
                self.latestRawFrame = frame.raw
                self.onFrame?(frame.raw, frame.rendered)
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
        let target = videoRange.start.seconds + songTime
        let end = videoRange.end.seconds
        // Past the video's end the last frame holds until the song seeks back.
        let clamped = min(target, end - 0.05)
        let current = player.currentTime().seconds
        if target >= end - 0.05 {
            if player.rate != 0 { player.pause() }
        } else if wantsPlayback, !defersPlayback, player.rate == 0 {
            player.play()
        }
        guard force || !current.isFinite || abs(current - clamped) > 0.2 else { return }
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
