import Accelerate
import AVFAudio
import Foundation

/// Head-related impulse responses rendered by the system's own HRTF.
///
/// An offline `AVAudioEngine` places a point source around a listener in an
/// `AVAudioEnvironmentNode` with the HRTFHQ algorithm and records one
/// impulse per direction: Apple's measured head model, used as data for our
/// convolution, with no download and no bundled HRTF set. Distance gain and
/// the environment's reverb are switched off; the room is ours. Responses
/// are cached per sample rate and direction (2° azimuth, 5° elevation) and
/// share one onset trim, so interaural delays are kept exactly.
nonisolated enum DSPSystemHRTF {
    struct Response: Sendable {
        let left: [Double]
        let right: [Double]

        /// One window for both ears. Keep the captured energy and fade only
        /// the negligible tail, rather than cutting every response at 6 ms.
        func windowed(from start: Int, minimumLength: Int, sampleRate: Double) -> Response {
            let count = min(self.left.count, self.right.count)
            var left = Array(self.left[start..<count])
            var right = Array(self.right[start..<count])
            let energy = zip(left, right).reduce(0.0) { $0 + $1.0 * $1.0 + $1.1 * $1.1 }
            let tailBudget = energy * 1e-6
            var tailEnergy = 0.0
            var lastActive = 0
            for index in left.indices.reversed() {
                tailEnergy += left[index] * left[index] + right[index] * right[index]
                if tailEnergy > tailBudget {
                    lastActive = index
                    break
                }
            }
            let fade = max(2, Int((sampleRate * 0.001).rounded()))
            let length = min(left.count, max(minimumLength, lastActive + 1 + fade))
            left = Array(left.prefix(length))
            right = Array(right.prefix(length))
            let fadeStart = max(0, length - fade)
            if fadeStart > lastActive, length - fadeStart > 1 {
                for index in fadeStart..<length {
                    let position = Double(index - fadeStart) / Double(length - fadeStart - 1)
                    let weight = 0.5 + 0.5 * cos(Double.pi * position)
                    left[index] *= weight
                    right[index] *= weight
                }
            }
            return Response(left: left, right: right)
        }
    }

    private struct Key: Hashable {
        let sampleRate: Double
        let azimuth: Int
        let elevation: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var raw: [Key: Response] = [:]
    nonisolated(unsafe) private static var trims: [Double: Int] = [:]
    nonisolated(unsafe) private static var unavailableRates: Set<Double> = []

    private static let azimuthStep = 2.0
    private static let elevationStep = 5.0
    /// Time kept ahead of the frontal onset for pre-ringing and ear delays.
    private static let onsetLeadSeconds = 0.001

    /// One response per direction, at least `minimumLength` frames, or nil when the
    /// system renderer is unavailable at this rate.
    /// - Parameter directions: radians; azimuth positive to the left.
    static func responses(for directions: [(azimuth: Double, elevation: Double)], sampleRate: Double,
                          minimumLength: Int) -> [Response]? {
        lock.lock()
        defer { lock.unlock() }
        guard !unavailableRates.contains(sampleRate) else { return nil }
        let frontal = Key(sampleRate: sampleRate, azimuth: 0, elevation: 0)
        let keys = directions.map { key(for: $0, sampleRate: sampleRate) }
        let missing = Array(Set(keys + [frontal]).filter { raw[$0] == nil })
        if !missing.isEmpty {
            guard let rendered = render(missing, sampleRate: sampleRate) else {
                unavailableRates.insert(sampleRate)
                return nil
            }
            if raw.count > 2_048 { raw.removeAll() }
            raw.merge(rendered) { _, new in new }
        }
        guard let reference = raw[frontal] else { return nil }
        let trim: Int
        if let known = trims[sampleRate] {
            trim = known
        } else {
            trim = onset(of: reference, sampleRate: sampleRate)
            trims[sampleRate] = trim
        }
        return keys.map { key in
            let response = raw[key] ?? reference
            return response.windowed(from: trim, minimumLength: minimumLength, sampleRate: sampleRate)
        }
    }

    private static func key(for direction: (azimuth: Double, elevation: Double), sampleRate: Double) -> Key {
        var degrees = direction.azimuth * 180 / Double.pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees <= -180 { degrees += 360 }
        let elevation = min(85, max(-85, direction.elevation * 180 / Double.pi))
        return Key(sampleRate: sampleRate,
                   azimuth: Int((degrees / azimuthStep).rounded()) * Int(azimuthStep),
                   elevation: Int((elevation / elevationStep).rounded()) * Int(elevationStep))
    }

    private static func onset(of response: Response, sampleRate: Double) -> Int {
        let envelope = zip(response.left, response.right).map { max(abs($0), abs($1)) }
        let peak = envelope.max() ?? 0
        guard peak > 0 else { return 0 }
        let first = envelope.firstIndex { $0 > peak * 0.001 } ?? 0
        return max(0, first - Int((sampleRate * onsetLeadSeconds).rounded()))
    }

    /// Renders every direction in one offline session. A position change
    /// glides inside the mixer, so each impulse follows a settling pause.
    private static func render(_ keys: [Key], sampleRate: Double) -> [Key: Response]? {
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        let engine = AVAudioEngine()
        let maximumFrames: AVAudioFrameCount = 4_096
        // Manual rendering goes first: touching mainMixerNode on a device-mode
        // engine opens the default devices, Bluetooth headset microphone included.
        do {
            try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: maximumFrames)
        } catch {
            return nil
        }
        let environment = AVAudioEnvironmentNode()
        let player = AVAudioPlayerNode()
        engine.attach(environment)
        engine.attach(player)
        engine.connect(player, to: environment, format: mono)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.outputType = .headphones
        environment.reverbParameters.enable = false
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.distanceAttenuationParameters.maximumDistance = 100
        environment.distanceAttenuationParameters.rolloffFactor = 1
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
        player.renderingAlgorithm = .HRTFHQ
        player.sourceMode = .pointSource
        player.position = position(of: keys[0])
        do {
            try engine.start()
        } catch {
            return nil
        }
        defer {
            player.stop()
            engine.stop()
        }
        player.play()

        let settle = Int(sampleRate * 0.1)
        let capture = Int(sampleRate * 0.04)
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrames)
        else { return nil }
        var results: [Key: Response] = [:]
        for key in keys {
            player.position = position(of: key)
            let total = settle + capture
            guard let impulse = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(total)),
                  let channel = impulse.floatChannelData?[0] else { return nil }
            impulse.frameLength = AVAudioFrameCount(total)
            channel.update(repeating: 0, count: total)
            channel[settle] = 1
            player.scheduleBuffer(impulse, completionHandler: nil)

            var left: [Double] = []
            var right: [Double] = []
            left.reserveCapacity(capture)
            right.reserveCapacity(capture)
            var rendered = 0
            while rendered < total {
                let request = AVAudioFrameCount(min(Int(maximumFrames), total - rendered))
                guard let status = try? engine.renderOffline(request, to: output), status == .success,
                      let data = output.floatChannelData, output.format.channelCount >= 2 else { return nil }
                let frames = Int(output.frameLength)
                guard frames > 0 else { return nil }
                for frame in 0..<frames where rendered + frame >= settle {
                    left.append(Double(data[0][frame]))
                    right.append(Double(data[1][frame]))
                }
                rendered += frames
            }
            guard left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite),
                  left.contains(where: { $0 != 0 }) || right.contains(where: { $0 != 0 }) else { return nil }
            results[key] = Response(left: left, right: right)
        }
        return results
    }

    /// One metre from the listener, who faces −z with +y up.
    private static func position(of key: Key) -> AVAudio3DPoint {
        let azimuth = Double(key.azimuth) * Double.pi / 180
        let elevation = Double(key.elevation) * Double.pi / 180
        return AVAudio3DPoint(x: Float(-sin(azimuth) * cos(elevation)),
                              y: Float(sin(elevation)),
                              z: Float(-cos(azimuth) * cos(elevation)))
    }
}

/// Spherical-head responses after Brown & Duda, "A Structural Model for
/// Binaural Sound Synthesis" (IEEE TSAP 1998): the head-shadow filter and
/// the head's interaural time delay. The fallback when the system HRTF is
/// unavailable. The paper's pinna echoes are left out: their deep combs
/// colour music far more than the elevation cue they add is worth here.
nonisolated enum DSPStructuralHRTF {
    enum Ear: Sendable {
        case left
        case right
    }

    static let headRadius = 0.0875
    static let speedOfSound = 343.0
    private static let minimumShadow = 0.1
    private static let shadowAngle = 150.0 * Double.pi / 180
    /// Leading frames reserved for the interpolation kernel.
    static let leadFrames = 16

    /// - Parameters:
    ///   - azimuth: radians, positive to the listener's left.
    ///   - elevation: radians, positive upward.
    static func impulseResponse(azimuth: Double, elevation: Double, ear: Ear,
                                sampleRate: Double, length: Int = 256) -> [Double] {
        var response = [Double](repeating: 0, count: length)
        let direction = (cos(elevation) * cos(azimuth), cos(elevation) * sin(azimuth), sin(elevation))
        let earAxis = ear == .left ? 1.0 : -1.0
        let incidence = acos(min(1, max(-1, direction.1 * earAxis)))

        // Interaural delay, shifted so the nearest incidence is zero.
        let headTime = headRadius / speedOfSound
        let delaySeconds = incidence < Double.pi / 2
            ? headTime * (1 - cos(incidence))
            : headTime * (1 + incidence - Double.pi / 2)
        addImpulse(&response, at: Double(leadFrames) + delaySeconds * sampleRate, gain: 1)

        // Head shadow: one pole and one zero whose ratio follows incidence.
        let alpha = (1 + minimumShadow / 2) + (1 - minimumShadow / 2) * cos(Double.pi * incidence / shadowAngle)
        let beta = 2 * speedOfSound / headRadius
        let k = 2 * sampleRate
        let norm = 1 / (k + beta)
        let b0 = (alpha * k + beta) * norm
        let b1 = (beta - alpha * k) * norm
        let a1 = (beta - k) * norm
        var x1 = 0.0
        var y1 = 0.0
        for index in response.indices {
            let x = response[index]
            let y = b0 * x + b1 * x1 - a1 * y1
            x1 = x
            y1 = y
            response[index] = y
        }
        return response
    }

    /// Adds a band-limited impulse at a fractional position (Blackman-windowed sinc).
    static func addImpulse(_ buffer: inout [Double], at position: Double, gain: Double) {
        let halfWidth = 8
        let center = Int(position.rounded(.down))
        let fraction = position - Double(center)
        for tap in -halfWidth...halfWidth {
            let index = center + tap
            guard index >= 0, index < buffer.count else { continue }
            let x = Double(tap) - fraction
            let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let w = (x + Double(halfWidth) + 1) / Double(2 * halfWidth + 2)
            let window = w <= 0 || w >= 1 ? 0 : 0.42 - 0.5 * cos(2 * Double.pi * w) + 0.08 * cos(4 * Double.pi * w)
            buffer[index] += gain * sinc * window
        }
    }
}

/// Binaural responses for two virtual loudspeakers in a quiet listening room.
///
/// The aim is speakers in front of the listener, not a reverberant space:
/// that is what the reverb node is for. Direct sound and first- and
/// second-order reflections of a shoebox room come from the image-source
/// method (Allen & Berkley 1979), each rendered through the head response
/// from its own direction with wall losses and a darker spectrum per bounce;
/// reflections are held 6 dB under the image-source level. A short late
/// tail from the reverb engine starts around the perceptual mixing time
/// (about √V ms, Lindau et al. 2012) and sits 10 dB under the direct sound.
/// The tail is rendered once per loudspeaker with its own seed so the two
/// stay uncorrelated; below 500 Hz each speaker's two ears share one tail,
/// approximating the coherence of a diffuse field at the head. Those three
/// levels are our own tuning for a light room.
///
/// A broad equalizer, the inverse of the octave-smoothed response of a
/// centred source within ±6 dB, keeps the phantom centre's timbre neutral,
/// as free-field equalization does for a measured HRTF. It is minimum
/// phase (homomorphic, Oppenheim & Schafer) and applies to every path, so
/// interaural differences are untouched.
nonisolated enum DSPRoomSynthesis {
    struct Room: Sendable {
        let length: Double
        let width: Double
        let height: Double
        let decaySeconds: Double
        let lowDecayRatio: Double
        let highDecayRatio: Double
        let lineCount: Int

        var volume: Double { length * width * height }
        var surface: Double { 2 * (length * width + length * height + width * height) }

        /// Average absorption from Sabine's formula, for the wall losses.
        var absorption: Double { min(0.95, 0.161 * volume / (surface * decaySeconds)) }

        static func preset(_ preset: DSPRoomPreset) -> Room? {
            switch preset {
            case .none: nil
            case .studio: Room(length: 5.6, width: 4.4, height: 2.8, decaySeconds: 0.25,
                               lowDecayRatio: 1.1, highDecayRatio: 0.7, lineCount: 8)
            }
        }
    }

    /// Paths, in order: left speaker to left ear, left speaker to right ear,
    /// right speaker to left ear, right speaker to right ear.
    struct Responses: Sendable {
        let paths: [[Double]]
        /// Speaker distance after fitting the speakers inside the room.
        let distance: Double
        /// Common centre arrival, preserving the ears' relative delays.
        let directDelayFrames: Int
    }

    private static let reflectionScale = 0.5
    private static let tailToDirect = 0.1
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Responses] = [:]

    static func responses(parameters: DSPSpatialAudioParameters, sampleRate: Double) -> Responses? {
        let key = "\(parameters.room.rawValue)|\(parameters.distanceM)|\(parameters.speakerAngleDeg)|\(sampleRate)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
        guard let synthesized = synthesize(room: Room.preset(parameters.room),
                                           distance: parameters.distanceM,
                                           angle: parameters.speakerAngleDeg * Double.pi / 180,
                                           sampleRate: sampleRate) else { return nil }
        lock.lock()
        if cache.count > 16 { cache.removeAll() }
        cache[key] = synthesized
        lock.unlock()
        return synthesized
    }

    private static func synthesize(room: Room?, distance requested: Double, angle: Double,
                                   sampleRate: Double) -> Responses? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let c = DSPStructuralHRTF.speedOfSound
        let earHeight = 1.2
        let margin = 0.4
        var distance = requested
        var listener = (x: 0.0, y: 0.0, z: earHeight)
        if let room {
            // Fit the speakers inside the room, then sit as far back as the
            // layout allows without touching the rear wall.
            let maximumForward = room.length - 2 * margin
            let maximumSide = room.width / 2 - margin
            distance = min(distance, maximumForward / max(cos(angle), 0.1), maximumSide / max(sin(angle), 0.1))
            distance = max(0.5, distance)
            listener = (x: max(margin, min(room.length * 0.5, room.length - margin - distance * cos(angle))),
                        y: room.width / 2, z: earHeight)
        }

        let tailSeconds = room.map { min(1.5, $0.decaySeconds * max(1, $0.lowDecayRatio) * 1.3) } ?? 0
        let directDelay = distance / c
        let leadSeconds = 0.002
        let minimumHRIRLength = Int(sampleRate * 0.006)

        let speakers = [
            (x: listener.x + distance * cos(angle), y: listener.y + distance * sin(angle), z: earHeight),
            (x: listener.x + distance * cos(angle), y: listener.y - distance * sin(angle), z: earHeight),
        ]
        let imageSets = speakers.map { imageSources(of: $0, room: room) }
        let images = imageSets.flatMap { $0 }
        let directions = images.map { image -> (azimuth: Double, elevation: Double) in
            let dx = image.x - listener.x, dy = image.y - listener.y, dz = image.z - listener.z
            return (atan2(dy, dx), atan2(dz, (dx * dx + dy * dy).squareRoot()))
        }
        let heads = headResponses(directions, sampleRate: sampleRate, minimumLength: minimumHRIRLength)
        let hrirLength = heads.map { max($0.left.count, $0.right.count) }.max() ?? minimumHRIRLength
        let directLength = Int(leadSeconds * sampleRate) + hrirLength + Int(sampleRate * equalizerDuration) + 1
        let length = room == nil ? directLength : max(directLength, Int((0.08 + tailSeconds) * sampleRate) + 1_024)

        var paths = Array(repeating: [Double](repeating: 0, count: length), count: 4)
        var directPaths = Array(repeating: [Double](repeating: 0, count: directLength), count: 4)
        let beta = room.map { (1 - $0.absorption).squareRoot() } ?? 1
        let highShelfGain = room.map { (1 - min(0.98, $0.absorption * 1.6)).squareRoot() / beta } ?? 1
        var headIndex = 0
        for (speakerIndex, speakerImages) in imageSets.enumerated() {
            for image in speakerImages {
                let head = heads[headIndex]
                headIndex += 1
                let dx = image.x - listener.x, dy = image.y - listener.y, dz = image.z - listener.z
                let range = max(0.3, (dx * dx + dy * dy + dz * dz).squareRoot())
                let scale = image.order == 0 ? 1 : reflectionScale
                let gain = scale * pow(beta, Double(image.order)) / range
                let start = Int(((range / c) - directDelay + leadSeconds) * sampleRate)
                for (earIndex, var hrir) in [head.left, head.right].enumerated() {
                    guard start >= 0, start + hrir.count <= length else { continue }
                    // Each bounce darkens the reflection a little more.
                    for _ in 0..<image.order {
                        var shelf = DSPFirstOrderSection.highShelf(gain: highShelfGain, frequency: 2_000,
                                                                  sampleRate: sampleRate)
                        for tap in hrir.indices { hrir[tap] = shelf.process(hrir[tap]) }
                    }
                    let path = speakerIndex * 2 + earIndex
                    for tap in hrir.indices {
                        let value = hrir[tap] * gain
                        paths[path][start + tap] += value
                        if image.order == 0 { directPaths[path][start + tap] += value }
                    }
                }
            }
        }

        // Calibrate the direct speakers before the room is added to the
        // measurement. A shared filter preserves the interaural differences.
        if let equalizer = centreEqualizer(directPaths, sampleRate: sampleRate) {
            for index in paths.indices {
                directPaths[index] = convolve(directPaths[index], with: equalizer)
                if room != nil { paths[index] = convolve(paths[index], with: equalizer) }
            }
        }
        if room == nil { paths = directPaths }
        let directDelayFrames = centreDelayFrames(directPaths)
        var left = (ear: paths[0], opposite: paths[1])
        var right = (ear: paths[3], opposite: paths[2])

        // Each speaker gets its own tail seed, so the two reverberations
        // stay uncorrelated.
        if let room {
            let startOffset = Int(leadSeconds * sampleRate)
            let leftEnergy = (directPaths[0] + directPaths[1]).reduce(0) { $0 + $1 * $1 } * 0.5
            let rightEnergy = (directPaths[2] + directPaths[3]).reduce(0) { $0 + $1 * $1 } * 0.5
            addTail(to: &left.ear, opposite: &left.opposite, room: room, directEnergy: leftEnergy,
                    startOffset: startOffset, sampleRate: sampleRate, seed: 0x5EED_0001)
            addTail(to: &right.ear, opposite: &right.opposite, room: room, directEnergy: rightEnergy,
                    startOffset: startOffset, sampleRate: sampleRate, seed: 0x5EED_0002)
        }

        paths = [left.ear, left.opposite, right.opposite, right.ear]
        normalize(&paths, sampleRate: sampleRate)
        return Responses(paths: paths, distance: distance, directDelayFrames: directDelayFrames)
    }

    private static func centreDelayFrames(_ paths: [[Double]]) -> Int {
        var peak = 0.0
        var delay = 0
        for index in paths[0].indices {
            let left = paths[0][index] + paths[2][index]
            let right = paths[1][index] + paths[3][index]
            let power = left * left + right * right
            if power > peak {
                peak = power
                delay = index
            }
        }
        return delay
    }

    /// The system HRTF when available, the spherical head otherwise.
    private static func headResponses(_ directions: [(azimuth: Double, elevation: Double)], sampleRate: Double,
                                      minimumLength: Int) -> [DSPSystemHRTF.Response] {
        if let system = DSPSystemHRTF.responses(for: directions, sampleRate: sampleRate, minimumLength: minimumLength) {
            return system
        }
        return directions.map { direction in
            DSPSystemHRTF.Response(
                left: DSPStructuralHRTF.impulseResponse(azimuth: direction.azimuth, elevation: direction.elevation,
                                                        ear: .left, sampleRate: sampleRate, length: minimumLength),
                right: DSPStructuralHRTF.impulseResponse(azimuth: direction.azimuth, elevation: direction.elevation,
                                                         ear: .right, sampleRate: sampleRate, length: minimumLength)
            )
        }
    }

    private struct Image {
        let x: Double
        let y: Double
        let z: Double
        let order: Int
    }

    /// Image sources up to second order (Allen & Berkley): each coordinate
    /// is (1 − 2p)·s + 2r·L with |r − p| + |r| reflections.
    private static func imageSources(of source: (x: Double, y: Double, z: Double), room: Room?) -> [Image] {
        guard let room else { return [Image(x: source.x, y: source.y, z: source.z, order: 0)] }
        var images: [Image] = []
        func axis(_ s: Double, _ length: Double) -> [(Double, Int)] {
            var result: [(Double, Int)] = []
            for p in 0...1 {
                for r in -1...1 {
                    result.append(((1 - 2 * Double(p)) * s + 2 * Double(r) * length, abs(r - p) + abs(r)))
                }
            }
            return result
        }
        for (x, ox) in axis(source.x, room.length) {
            for (y, oy) in axis(source.y, room.width) {
                for (z, oz) in axis(source.z, room.height) where ox + oy + oz <= 2 {
                    images.append(Image(x: x, y: y, z: z, order: ox + oy + oz))
                }
            }
        }
        return images
    }

    /// Perceptual mixing time, about √V milliseconds for volume V in m³.
    private static func mixingTime(_ room: Room) -> Double {
        room.volume.squareRoot() / 1_000
    }

    private static func addTail(to ear: inout [Double], opposite: inout [Double], room: Room,
                                directEnergy: Double, startOffset: Int, sampleRate: Double, seed: UInt64) {
        let mid = room.decaySeconds
        let span = (room.volume.squareRoot() / 6).rounded()
        let design = DSPReverbDesign(
            topology: .feedbackDelayNetwork(lineCount: room.lineCount,
                                            minimumDelayMs: max(4, span * 1.2), maximumDelayMs: max(20, span * 6)),
            lowDecaySeconds: mid * room.lowDecayRatio, midDecaySeconds: mid,
            highDecaySeconds: mid * room.highDecayRatio, preDelayMs: 0, lowCutHz: 20, seed: seed
        )
        guard var reverb = DSPReverbKernel(sampleRate: sampleRate, leftChannel: 0, rightChannel: 1,
                                           design: design, mix: nil, calibrate: false) else { return }
        let count = ear.count - startOffset
        guard count > 0 else { return }
        var rendered = [Double](repeating: 0, count: count * 2)
        rendered[0] = 1
        rendered.withUnsafeMutableBufferPointer { buffer in
            reverb.process(buffer.baseAddress!, frames: count, channels: 2)
        }
        var own = (0..<count).map { rendered[$0 * 2] }
        var other = (0..<count).map { rendered[$0 * 2 + 1] }

        // Shared low end: below 500 Hz the opposite ear takes the own-side
        // tail through a Linkwitz–Riley split, keeping the magnitude flat.
        if let lowPass = DSPFilterDesign.section(.lowPass, frequencyHz: 500, sampleRate: sampleRate),
           let highPass = DSPFilterDesign.section(.highPass, frequencyHz: 500, sampleRate: sampleRate) {
            var lp1 = DSPBiquad(lowPass), lp2 = DSPBiquad(lowPass)
            var hp1 = DSPBiquad(highPass), hp2 = DSPBiquad(highPass)
            for index in 0..<count {
                other[index] = lp2.process(lp1.process(own[index])) + hp2.process(hp1.process(other[index]))
            }
            if var allpass = DSPFilterDesign.linkwitzRileyAllpass(frequencyHz: 500, sampleRate: sampleRate)
                .map(DSPBiquad.init) {
                for index in 0..<count { own[index] = allpass.process(own[index]) }
            }
        }

        // Fade in across the mixing time.
        let mixing = mixingTime(room) * sampleRate
        let fadeStart = Int(mixing * 0.5)
        let fadeEnd = max(fadeStart + 1, Int(mixing))
        var tailEnergy = 0.0
        for index in 0..<count {
            let weight: Double
            if index < fadeStart {
                weight = 0
            } else if index < fadeEnd {
                weight = 0.5 - 0.5 * cos(Double.pi * Double(index - fadeStart) / Double(fadeEnd - fadeStart))
            } else {
                weight = 1
            }
            own[index] *= weight
            other[index] *= weight
            tailEnergy += (own[index] * own[index] + other[index] * other[index]) * 0.5
        }

        let gain = tailEnergy > 0 ? (directEnergy * tailToDirect / tailEnergy).squareRoot() : 0
        for index in 0..<count {
            ear[startOffset + index] += own[index] * gain
            opposite[startOffset + index] += other[index] * gain
        }
    }

    // MARK: Centre equalization

    private static let equalizerSize = 8_192
    private static let equalizerLimitDB = 6.0
    private static let equalizerDuration = 1_024.0 / 48_000

    /// Minimum-phase inverse of a centred source's octave-smoothed response
    /// across both ears, level-neutral at 500–2000 Hz. Only direct paths enter.
    private static func centreEqualizer(_ paths: [[Double]], sampleRate: Double) -> [Double]? {
        guard paths.count == 4 else { return nil }
        let span = paths[0].count
        var size = equalizerSize
        while size < span * 2 { size *= 2 }
        guard let transform = DSPComplexTransform(size: size) else { return nil }
        let half = size / 2
        var power = [Double](repeating: 0, count: half + 1)
        for ear in 0..<2 {
            var real = [Double](repeating: 0, count: size)
            var imaginary = [Double](repeating: 0, count: size)
            for index in 0..<span { real[index] = paths[ear][index] + paths[ear + 2][index] }
            transform.forward(&real, &imaginary)
            for bin in 0...half { power[bin] += (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) * 0.5 }
        }
        let binHz = sampleRate / Double(size)
        // Octave smoothing by prefix sums over [f/√2, f·√2].
        var prefix = [Double](repeating: 0, count: half + 2)
        for bin in 0...half { prefix[bin + 1] = prefix[bin] + power[bin] }
        let smoothed = (0...half).map { bin -> Double in
            let f = max(Double(bin), 1) * binHz
            let low = max(0, Int((f / 2.0.squareRoot() / binHz).rounded(.down)))
            let high = min(half, max(low, Int((f * 2.0.squareRoot() / binHz).rounded(.up))))
            return (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
        }
        power = smoothed
        // Correction in dB, held flat outside 60 Hz–16 kHz.
        func correctionDB(_ bin: Int) -> Double {
            let f = Double(bin) * binHz
            let held = Int((min(max(f, 60), min(16_000, sampleRate * 0.45)) / binHz).rounded())
            return -10 * log10(max(power[min(half, held)], 1e-24))
        }
        var reference = 0.0
        var referenceCount = 0.0
        for bin in Int(500 / binHz)...Int(2_000 / binHz) {
            reference += correctionDB(bin)
            referenceCount += 1
        }
        reference /= max(referenceCount, 1)
        // Log magnitude in nepers, symmetric for a real response.
        var logMagnitude = [Double](repeating: 0, count: size)
        for bin in 0...half {
            let dB = min(equalizerLimitDB, max(-equalizerLimitDB, correctionDB(bin) - reference))
            logMagnitude[bin] = dB / 20 * log(10)
            if bin > 0, bin < half { logMagnitude[size - bin] = logMagnitude[bin] }
        }

        // Real cepstrum, folded onto positive quefrency: minimum phase.
        var cepstrum = logMagnitude
        var cepstrumImaginary = [Double](repeating: 0, count: size)
        transform.inverse(&cepstrum, &cepstrumImaginary)
        for index in 1..<half { cepstrum[index] *= 2 }
        for index in (half + 1)..<size { cepstrum[index] = 0 }
        cepstrumImaginary = [Double](repeating: 0, count: size)
        transform.forward(&cepstrum, &cepstrumImaginary)
        var spectrumReal = [Double](repeating: 0, count: size)
        var spectrumImaginary = [Double](repeating: 0, count: size)
        for bin in 0..<size {
            let magnitude = exp(cepstrum[bin])
            spectrumReal[bin] = magnitude * cos(cepstrumImaginary[bin])
            spectrumImaginary[bin] = magnitude * sin(cepstrumImaginary[bin])
        }
        transform.inverse(&spectrumReal, &spectrumImaginary)
        // Keep the same physical duration at every sample rate.
        let taps = max(32, Int((sampleRate * equalizerDuration).rounded()))
        let fade = taps / 8
        let filter = (0..<taps).map { index -> Double in
            let window = index < taps - fade
                ? 1 : 0.5 + 0.5 * cos(Double.pi * Double(index - (taps - fade)) / Double(fade))
            return spectrumReal[index] * window
        }
        return filter.allSatisfy(\.isFinite) ? filter : nil
    }

    /// Causal convolution truncated to the signal's length.
    private static func convolve(_ signal: [Double], with filter: [Double]) -> [Double] {
        let taps = filter.count
        guard taps > 0, !signal.isEmpty else { return signal }
        let padded = [Double](repeating: 0, count: taps - 1) + signal
        var result = [Double](repeating: 0, count: signal.count)
        filter.withUnsafeBufferPointer { kernel in
            vDSP_convD(padded, 1, kernel.baseAddress! + taps - 1, -1, &result, 1,
                       vDSP_Length(signal.count), vDSP_Length(taps))
        }
        return result
    }

    /// Scales every path so each ear's pink-noise power equals one input
    /// channel's for uncorrelated left and right inputs.
    private static func normalize(_ paths: inout [[Double]], sampleRate: Double) {
        let leftEar = pinkEnergy(paths[0]) + pinkEnergy(paths[2])
        let rightEar = pinkEnergy(paths[1]) + pinkEnergy(paths[3])
        let reference = pinkEnergy([1])
        let average = (leftEar + rightEar) / 2
        guard average > 0, reference > 0 else { return }
        let gain = (reference / average).squareRoot()
        for path in paths.indices {
            for index in paths[path].indices { paths[path][index] *= gain }
        }
    }

    /// Energy of a response shaped by Kellet's pink filter, with the
    /// filter's own decay included.
    static func pinkEnergy(_ response: [Double]) -> Double {
        var state = (0.0, 0.0, 0.0)
        var energy = 0.0
        let extra = 2_048
        for index in 0..<(response.count + extra) {
            let white = index < response.count ? response[index] : 0
            state.0 = 0.99765 * state.0 + white * 0.0990460
            state.1 = 0.96300 * state.1 + white * 0.2965164
            state.2 = 0.57000 * state.2 + white * 1.0526913
            let pink = state.0 + state.1 + state.2 + white * 0.1848
            energy += pink * pink
        }
        return energy
    }
}

/// Complex DFT of one fixed size; the inverse is scaled by 1/N.
nonisolated final class DSPComplexTransform {
    private let size: Int
    private let forwardSetup: vDSP_DFT_SetupD
    private let inverseSetup: vDSP_DFT_SetupD

    init?(size: Int) {
        guard let forward = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(size), .FORWARD) else { return nil }
        guard let inverse = vDSP_DFT_zop_CreateSetupD(forward, vDSP_Length(size), .INVERSE) else {
            vDSP_DFT_DestroySetupD(forward)
            return nil
        }
        self.size = size
        forwardSetup = forward
        inverseSetup = inverse
    }

    deinit {
        vDSP_DFT_DestroySetupD(inverseSetup)
        vDSP_DFT_DestroySetupD(forwardSetup)
    }

    func forward(_ real: inout [Double], _ imaginary: inout [Double]) {
        execute(forwardSetup, &real, &imaginary, scale: 1)
    }

    func inverse(_ real: inout [Double], _ imaginary: inout [Double]) {
        execute(inverseSetup, &real, &imaginary, scale: 1 / Double(size))
    }

    private func execute(_ setup: vDSP_DFT_SetupD, _ real: inout [Double], _ imaginary: inout [Double], scale: Double) {
        let inputReal = real
        let inputImaginary = imaginary
        vDSP_DFT_ExecuteD(setup, inputReal, inputImaginary, &real, &imaginary)
        if scale != 1 {
            for index in 0..<size {
                real[index] *= scale
                imaginary[index] *= scale
            }
        }
    }
}
