//
//  DSPCardVisualSupport.swift
//  myPlayer2
//
//  Shared pieces of the effect-card visuals: one 48-band spectrum taken from
//  the shared analysis service, a layer-hosting view driven by a display link
//  at the screen's own maximum rate, and banks of MotionKit spring followers.
//
//  Per-frame work writes only into layers or GPU buffers and never touches
//  SwiftUI state. Analysis data arrives at no more than 30 Hz and only moves
//  follower targets; the followers interpolate every display frame. The link
//  pauses once everything has settled, while the view is hidden or occluded,
//  and when it leaves its window; it never runs below the screen's rate.
//

import AppKit
import MotionKit
import QuartzCore

// MARK: - Shared spectrum

/// Log-spaced band levels of the playing signal, 20 Hz to 20 kHz, shared by
/// every effect card. It is a consumer of `AudioAnalysisHub` while at least
/// one card holds a lease, so no card installs its own tap or FFT.
nonisolated final class DSPCardSpectrumFeed: @unchecked Sendable {
    static let shared = DSPCardSpectrumFeed()

    static let bandCount = 48
    static let lowestHz = 20.0
    static let highestHz = 20_000.0
    /// Band levels map −72…−12 dBFS onto 0…1.
    private static let floorDB: Float = -72
    private static let rangeDB: Float = 60
    /// A full-scale sine through the hub's Hann window and real FFT reads
    /// (N/2)² in power; this offset turns band power into dBFS.
    private static func fullScaleOffsetDB(fftSize: Int) -> Float {
        20 * log10(Float(fftSize) / 2)
    }

    private let lock = NSLock()
    private var leaseCount = 0
    private var consumerID: UUID?
    private var bands = [Float](repeating: 0, count: DSPCardSpectrumFeed.bandCount)
    private var level: Float = 0
    private var updateTime: TimeInterval = -.infinity

    // Touched only on the hub's serial processing queue.
    private var binRanges: [Range<Int>] = []
    private var binKey = (sampleRate: Float(0), fftSize: 0)
    private var scratch = [Float](repeating: 0, count: DSPCardSpectrumFeed.bandCount)

    /// Starts the feed for one more card.
    func acquire() {
        lock.lock()
        leaseCount += 1
        let shouldStart = leaseCount == 1
        lock.unlock()
        guard shouldStart else { return }
        let id = AudioAnalysisHub.shared.addConsumer { [weak self] data in
            self?.ingest(data)
        }
        lock.lock()
        if leaseCount > 0, consumerID == nil {
            consumerID = id
            lock.unlock()
        } else {
            lock.unlock()
            AudioAnalysisHub.shared.removeConsumer(id)
        }
    }

    func release() {
        lock.lock()
        leaseCount = max(0, leaseCount - 1)
        let id = leaseCount == 0 ? consumerID : nil
        if id != nil { consumerID = nil }
        lock.unlock()
        if let id { AudioAnalysisHub.shared.removeConsumer(id) }
    }

    /// Copies the newest band levels into `destination` (resized only when
    /// its count differs) and returns the broadband level. Values older than
    /// `maximumAge` read as silence, so a paused player settles to rest.
    @discardableResult
    func read(into destination: inout [Float], maximumAge: TimeInterval = 0.2) -> Float {
        if destination.count != Self.bandCount {
            destination = [Float](repeating: 0, count: Self.bandCount)
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard now - updateTime <= maximumAge else {
            for index in destination.indices { destination[index] = 0 }
            return 0
        }
        for index in 0..<Self.bandCount { destination[index] = bands[index] }
        return level
    }

    private func ingest(_ data: AudioAnalysisData) {
        let binCount = data.magnitudes.count
        guard binCount > 1, data.sampleRate > 0 else { return }
        if binKey.sampleRate != data.sampleRate || binKey.fftSize != data.fftSize || binRanges.isEmpty {
            binRanges = Self.makeBinRanges(sampleRate: Double(data.sampleRate), fftSize: data.fftSize, binCount: binCount)
            binKey = (data.sampleRate, data.fftSize)
        }
        let offset = Self.fullScaleOffsetDB(fftSize: data.fftSize)
        data.magnitudes.withUnsafeBufferPointer { power in
            for (band, range) in binRanges.enumerated() {
                var sum: Float = 0
                for bin in range where bin < binCount { sum += power[bin] }
                let dB = 10 * log10(max(sum, 1e-20)) - offset
                scratch[band] = min(1, max(0, (dB - Self.floorDB) / Self.rangeDB))
            }
        }
        let rmsDB = 20 * log10(max(data.rms, 1e-9))
        // RMS sits about 3 dB under a sine's peak; −54…−6 dBFS maps to 0…1.
        let broadband = min(1, max(0, (rmsDB + 54) / 48))

        lock.lock()
        for index in 0..<Self.bandCount { bands[index] = scratch[index] }
        level = broadband
        updateTime = ProcessInfo.processInfo.systemUptime
        let due = wakers
        if !due.isEmpty { wakers.removeAll() }
        lock.unlock()
        guard !due.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for waker in due.values { waker() } }
        }
    }

    private var wakers: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]

    /// Runs `action` once on the main actor when the next analysis frame
    /// arrives, so a resting visual can stop its display link.
    func wakeOnNextUpdate(owner: AnyObject, _ action: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        wakers[ObjectIdentifier(owner)] = action
        lock.unlock()
    }

    func cancelWake(owner: AnyObject) {
        lock.lock()
        wakers.removeValue(forKey: ObjectIdentifier(owner))
        lock.unlock()
    }

    private static func makeBinRanges(sampleRate: Double, fftSize: Int, binCount: Int) -> [Range<Int>] {
        let binHz = sampleRate / Double(fftSize)
        let ratio = highestHz / lowestHz
        return (0..<bandCount).map { band in
            let low = lowestHz * pow(ratio, Double(band) / Double(bandCount))
            let high = lowestHz * pow(ratio, Double(band + 1) / Double(bandCount))
            let first = max(1, Int((low / binHz).rounded(.down)))
            let last = max(first + 1, Int((high / binHz).rounded(.up)))
            return min(first, binCount - 1)..<min(last, binCount)
        }
    }

    /// Centre frequency of a band, for visuals that compute per-band values.
    static func centerFrequency(ofBand band: Int) -> Double {
        lowestHz * pow(highestHz / lowestHz, (Double(band) + 0.5) / Double(bandCount))
    }

    /// Position of `frequency` on the shared log axis, 0 at 20 Hz and 1 at 20 kHz.
    static func axisPosition(of frequency: Double) -> Double {
        let clamped = min(max(frequency, lowestHz), highestHz)
        return log(clamped / lowestHz) / log(highestHz / lowestHz)
    }
}

// MARK: - Display-link host

/// Layer-hosting base view for an animated effect-card visual. Subclasses
/// implement `renderFrame(at:)` and call `wake()` whenever a target changes.
@MainActor
class DSPCardAnimatedView: NSView {
    /// Resolved MotionKit policy of the surrounding SwiftUI environment.
    var motionPolicy: MotionPolicy = .full {
        didSet {
            guard motionPolicy != oldValue else { return }
            motionPolicyDidChange()
            wake()
        }
    }

    private var frameLink: CADisplayLink?
    private weak var observedWindow: NSWindow?
    private(set) var isVisibleOnScreen = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: the layer is set before `wantsLayer`, and sublayers
        // use top-left geometry like the view.
        layer = makeBackingLayer()
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
            frameLink?.invalidate()
        }
    }

    /// Advances and draws one frame at `time` (`CACurrentMediaTime` base).
    /// Returns true while anything still moves.
    func renderFrame(at time: CFTimeInterval) -> Bool { false }

    /// Called when the view starts or stops being visible on screen.
    func visibilityDidChange(_ isVisible: Bool) {}

    func motionPolicyDidChange() {}

    /// Resumes the display link after a target change.
    func wake() {
        guard isVisibleOnScreen else { return }
        ensureDisplayLink()
        frameLink?.isPaused = false
    }

    /// Draws the current state once without starting the link.
    func renderStill() {
        _ = renderFrame(at: CACurrentMediaTime())
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        boundsDidChange()
        renderStill()
        wake()
    }

    /// Called after the size changes, before the next frame is drawn.
    func boundsDidChange() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        invalidateDisplayLink()
        reconcileVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reconcileVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcileVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderStill()
    }

    private func reconcileVisibility() {
        let visible: Bool
        if let window {
            visible = window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
                && !isHiddenOrHasHiddenAncestor
        } else {
            visible = false
        }
        guard visible != isVisibleOnScreen else { return }
        isVisibleOnScreen = visible
        visibilityDidChange(visible)
        if visible {
            renderStill()
            wake()
        } else {
            frameLink?.isPaused = true
        }
    }

    private func ensureDisplayLink() {
        guard frameLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(handleFrame(_:)))
        // Follow the screen's own maximum: 60 on a 60 Hz display, 120 on
        // ProMotion. Never request less while running.
        let maximum = Float(max(60, window?.screen?.maximumFramesPerSecond ?? 120))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
        link.add(to: .current, forMode: .common)
        frameLink = link
    }

    private func invalidateDisplayLink() {
        frameLink?.invalidate()
        frameLink = nil
    }

    @objc private func handleFrame(_ link: CADisplayLink) {
        let keepRunning = renderFrame(at: link.targetTimestamp)
        if !keepRunning { link.isPaused = true }
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        if notification.name == NSWindow.didChangeScreenNotification {
            // The link binds to a screen; rebuild it for the new maximum.
            invalidateDisplayLink()
        }
        reconcileVisibility()
        if isVisibleOnScreen { wake() }
    }

    private func observeWindow() {
        guard observedWindow !== window else { return }
        let center = NotificationCenter.default
        if let observedWindow {
            for name in Self.windowNotifications {
                center.removeObserver(self, name: name, object: observedWindow)
            }
        }
        observedWindow = window
        guard let window else { return }
        for name in Self.windowNotifications {
            center.addObserver(self, selector: #selector(windowStateChanged(_:)), name: name, object: window)
        }
    }

    private static let windowNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.didChangeScreenNotification,
    ]
}

// MARK: - Followers

/// A bank of MotionKit spring followers. Targets may change at any moment;
/// each follower keeps its position and velocity across retargets.
struct DSPFollowerBank {
    private var states: [MotionRetargetState]
    private var settled: [Bool]
    private var baseSpec: MotionSpec
    private var policy: MotionPolicy

    init(count: Int, spec: MotionSpec, policy: MotionPolicy, initialValue: Double = 0) {
        baseSpec = spec
        self.policy = policy
        let resolved = policy.resolve(spec) ?? spec
        states = Array(repeating: MotionRetargetState(value: initialValue, spec: resolved), count: count)
        settled = Array(repeating: true, count: count)
    }

    var count: Int { states.count }

    func value(_ index: Int) -> Double { states[index].value }

    func target(_ index: Int) -> Double { states[index].target }

    var isSettled: Bool { !settled.contains(false) }

    /// Rebuilds the followers for a new spec or policy, keeping their state.
    mutating func update(spec: MotionSpec, policy: MotionPolicy) {
        guard spec != baseSpec || policy != self.policy else { return }
        baseSpec = spec
        self.policy = policy
        let resolved = policy.resolve(spec) ?? spec
        for index in states.indices {
            let old = states[index]
            states[index] = MotionRetargetState(value: old.value, velocity: old.velocity, target: old.target, spec: resolved)
            if policy == .disabled {
                states[index].snap(to: old.target)
                settled[index] = true
            } else if !settled[index] {
                states[index].retarget(to: old.target, at: CACurrentMediaTime())
            }
        }
    }

    /// Moves follower `index` toward `target`; tiny changes are ignored so a
    /// steady input lets the bank settle.
    mutating func setTarget(_ target: Double, at index: Int, time: CFTimeInterval, epsilon: Double = 0.0005) {
        guard abs(states[index].target - target) > epsilon else { return }
        if policy == .disabled {
            states[index].snap(to: target)
            settled[index] = true
        } else {
            states[index].retarget(to: target, at: time)
            settled[index] = false
        }
    }

    /// Jumps every follower to its target.
    mutating func snapAll() {
        for index in states.indices {
            states[index].snap(to: states[index].target)
            settled[index] = true
        }
    }

    /// Advances the moving followers. Returns true while any still moves.
    @discardableResult
    mutating func advance(to time: CFTimeInterval, epsilon: Double = 0.0008) -> Bool {
        var moving = false
        for index in states.indices where !settled[index] {
            if states[index].isSettled(at: time, positionEpsilon: epsilon, velocityEpsilon: epsilon * 4) {
                states[index].snap(to: states[index].target)
                settled[index] = true
            } else {
                moving = true
            }
        }
        return moving
    }
}

// MARK: - Colours

/// Flat colours for a card visual, resolved once per theme change.
struct DSPCardVisualColors: Equatable {
    var accent: CGColor
    /// Ink of the current appearance: white in dark mode, black in light.
    var ink: CGColor
    var isDark: Bool

    init(accent: NSColor, isDark: Bool) {
        self.accent = (accent.usingColorSpace(.sRGB) ?? accent).cgColor
        ink = isDark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
        self.isDark = isDark
    }

    static func == (lhs: DSPCardVisualColors, rhs: DSPCardVisualColors) -> Bool {
        lhs.isDark == rhs.isDark && lhs.accent == rhs.accent
    }

    func accent(alpha: CGFloat) -> CGColor {
        accent.copy(alpha: alpha) ?? accent
    }

    func ink(alpha: CGFloat) -> CGColor {
        ink.copy(alpha: alpha) ?? ink
    }

    /// Frequency hue from red at 20 Hz to violet at 20 kHz. The rainbow is a
    /// data encoding of frequency, the one recorded exception to the semantic
    /// palette; lightness and saturation follow the appearance.
    func frequencyColor(position: Double) -> (red: Float, green: Float, blue: Float) {
        let hue = 0.78 * min(max(position, 0), 1)
        let saturation = isDark ? 0.62 : 0.7
        let brightness = isDark ? 0.95 : 0.78
        let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB) ?? .white
        return (Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent))
    }
}
