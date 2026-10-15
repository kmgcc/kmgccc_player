import Foundation

/// Mid/side width with a side-channel low shelf.
///
/// The side signal passes a second-order low shelf (RBJ, slope S = 1) before
/// it is scaled, the frequency shaping of a Blumlein shuffler: bass widens
/// less than the rest, with a smooth transition over about two octaves and
/// never collapsed to mono. The mid signal is untouched, so the mono sum is
/// unaffected except for the slow loudness gain.
///
/// Two slow controls follow. An over-widening guard (our own combination,
/// validated separately) limits widening so the side-to-mid energy above
/// the crossover stays below `maximumSideRatio`; it never narrows a source.
/// The loudness gain only lifts a narrowed image back to the input's L²+R²
/// energy, by at most 3 dB. A widened image keeps the mid at unity: scaling
/// the whole signal down to offset the added side energy would also lower
/// the centre, which is heard as the effect making music quieter. For the
/// same reason widening reserves no automatic headroom.
nonisolated struct DSPStereoWidthKernel: DSPBlockKernel {
    private static let smoothingSeconds = 1.0
    private static let maximumLoudnessGain = pow(10, 3.0 / 20)
    private static let silence = 1e-10

    let leftChannel: Int
    let rightChannel: Int
    private let width: Double
    private let usesShelf: Bool
    private let usesGuard: Bool
    private let maximumSideRatio: Double
    private let loudnessMatchEnabled: Bool
    private let outputGain: Double
    private let smoothingFrames: Double
    private var shelf: DSPBiquad
    private var midHighPass: DSPBiquad
    private var sideHighPass: DSPBiquad
    private var highMidEnergy = 0.0
    private var highSideEnergy = 0.0
    private var midEnergy = 0.0
    private var sideEnergy = 0.0
    private var shapedSideEnergy = 0.0
    private var hasEstimate = false
    private var appliedWidth: Double
    private var appliedGain = 1.0
    private var midScratch: [Double] = []
    private var sideScratch: [Double] = []

    let stateBytes = 256

    init?(leftChannel: Int, rightChannel: Int, sampleRate: Double, parameters: DSPStereoWidthParameters) {
        let width = parameters.width
        let lowWidth = width > 1 ? 1 + parameters.lowWidthRatio * (width - 1) : width
        usesShelf = width > 1
        let shelfGainDB = usesShelf ? 20 * log10(lowWidth / width) : 0
        guard let shelf = DSPFilterDesign.section(.lowShelf, frequencyHz: parameters.crossoverHz,
                                                  sampleRate: sampleRate, q: 1, gainDB: shelfGainDB),
              let midHighPass = DSPFilterDesign.section(.highPass, frequencyHz: parameters.crossoverHz, sampleRate: sampleRate),
              let sideHighPass = DSPFilterDesign.section(.highPass, frequencyHz: parameters.crossoverHz, sampleRate: sampleRate)
        else { return nil }
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
        self.width = width
        usesGuard = width > 1
        maximumSideRatio = parameters.maximumSideRatio
        loudnessMatchEnabled = parameters.loudnessMatchEnabled
        outputGain = pow(10, parameters.outputTrimDB / 20)
        smoothingFrames = Self.smoothingSeconds * sampleRate
        self.shelf = DSPBiquad(shelf)
        self.midHighPass = DSPBiquad(midHighPass)
        self.sideHighPass = DSPBiquad(sideHighPass)
        // Widening starts where the guard would allow it on a typical mix.
        appliedWidth = width
    }

    func makeFreshState() -> DSPStereoWidthKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPStereoWidthKernel) {
        shelf.copyState(from: source.shelf)
        midHighPass.copyState(from: source.midHighPass)
        sideHighPass.copyState(from: source.sideHighPass)
        highMidEnergy = source.highMidEnergy
        highSideEnergy = source.highSideEnergy
        midEnergy = source.midEnergy
        sideEnergy = source.sideEnergy
        shapedSideEnergy = source.shapedSideEnergy
        hasEstimate = source.hasEstimate
        appliedGain = source.appliedGain
        // A new width glides from the old one instead of jumping.
        appliedWidth = source.appliedWidth
    }

    mutating func reset() {
        shelf.reset()
        midHighPass.reset()
        sideHighPass.reset()
        highMidEnergy = 0
        highSideEnergy = 0
        midEnergy = 0
        sideEnergy = 0
        shapedSideEnergy = 0
        hasEstimate = false
        appliedGain = 1
        appliedWidth = width
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        guard frames > 0 else { return }
        if midScratch.count < frames {
            midScratch = Array(repeating: 0, count: frames)
            sideScratch = Array(repeating: 0, count: frames)
        }
        var mids = midScratch
        midScratch = []
        var sides = sideScratch
        sideScratch = []
        defer {
            midScratch = mids
            sideScratch = sides
        }

        // Pass 1: split, shape the side and measure the block.
        var blockHighMid = 0.0, blockHighSide = 0.0, blockMid = 0.0, blockSide = 0.0, blockShaped = 0.0
        var shelf = shelf, midHighPass = midHighPass, sideHighPass = sideHighPass
        let usesShelf = usesShelf
        mids.withUnsafeMutableBufferPointer { mid in
            sides.withUnsafeMutableBufferPointer { side in
                for frame in 0..<frames {
                    let base = frame * channels
                    let left = samples[base + leftChannel]
                    let right = samples[base + rightChannel]
                    let m = (left + right) * 0.5
                    let s = (left - right) * 0.5
                    let shaped = usesShelf ? shelf.process(s) : s
                    let highMid = midHighPass.process(m)
                    let highSide = sideHighPass.process(s)
                    blockHighMid += highMid * highMid
                    blockHighSide += highSide * highSide
                    blockMid += m * m
                    blockSide += s * s
                    blockShaped += shaped * shaped
                    mid[frame] = m
                    side[frame] = shaped
                }
            }
        }
        self.shelf = shelf
        self.midHighPass = midHighPass
        self.sideHighPass = sideHighPass

        // Slow estimates; silence holds the last decision.
        let scale = 1 / Double(frames)
        if blockMid + blockSide > Self.silence * Double(frames) {
            if hasEstimate {
                let alpha = 1 - exp(-Double(frames) / smoothingFrames)
                highMidEnergy += alpha * (blockHighMid * scale - highMidEnergy)
                highSideEnergy += alpha * (blockHighSide * scale - highSideEnergy)
                midEnergy += alpha * (blockMid * scale - midEnergy)
                sideEnergy += alpha * (blockSide * scale - sideEnergy)
                shapedSideEnergy += alpha * (blockShaped * scale - shapedSideEnergy)
            } else {
                highMidEnergy = blockHighMid * scale
                highSideEnergy = blockHighSide * scale
                midEnergy = blockMid * scale
                sideEnergy = blockSide * scale
                shapedSideEnergy = blockShaped * scale
                hasEstimate = true
            }
        }

        var targetWidth = width
        if usesGuard, hasEstimate {
            let ratio = highSideEnergy / max(highMidEnergy, Self.silence)
            let allowed = (maximumSideRatio / max(ratio, Self.silence)).squareRoot()
            targetWidth = min(width, max(1, allowed))
        }
        var targetGain = 1.0
        if loudnessMatchEnabled, hasEstimate {
            let before = midEnergy + sideEnergy
            let after = midEnergy + targetWidth * targetWidth * shapedSideEnergy
            if before > Self.silence, after > Self.silence {
                targetGain = min(Self.maximumLoudnessGain, max(1, (before / after).squareRoot()))
            }
        }

        // Pass 2: glide both controls across the block and rebuild L/R.
        let startWidth = appliedWidth
        let startGain = appliedGain
        let widthStep = (targetWidth - startWidth) * scale
        let gainStep = (targetGain - startGain) * scale
        let outputGain = outputGain
        mids.withUnsafeBufferPointer { mid in
            sides.withUnsafeBufferPointer { side in
                for frame in 0..<frames {
                    let position = Double(frame + 1)
                    let w = startWidth + widthStep * position
                    let g = (startGain + gainStep * position) * outputGain
                    let m = mid[frame] * g
                    let s = side[frame] * w * g
                    let base = frame * channels
                    samples[base + leftChannel] = m + s
                    samples[base + rightChannel] = m - s
                }
            }
        }
        appliedWidth = targetWidth
        appliedGain = targetGain
    }
}

/// Bauer stereophonic-to-binaural crossfeed after libbs2b (Boris Mikhaylov,
/// MIT): the opposite channel arrives through a first-order low-pass, the
/// own channel through a first-order high boost that restores the treble the
/// mix would otherwise lose, and a fixed gain keeps bass level unchanged.
nonisolated struct DSPCrossfeedKernel: DSPBlockKernel {
    let leftChannel: Int
    let rightChannel: Int
    private let lowA0: Double
    private let lowB1: Double
    private let highA0: Double
    private let highA1: Double
    private let highB1: Double
    private let gain: Double
    private var lowLeft = 0.0
    private var lowRight = 0.0
    private var highLeft = 0.0
    private var highRight = 0.0
    private var previousLeft = 0.0
    private var previousRight = 0.0

    let stateBytes = 64

    init?(leftChannel: Int, rightChannel: Int, sampleRate: Double, parameters: DSPCrossfeedParameters) {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
        // bs2b's design: the feed level splits between the low-pass gain and
        // the high boost, and the boost corner follows from both.
        let level = parameters.feedDB
        let lowGainDB = level * -5 / 6 - 3
        let highGainDB = level / 6 - 3
        let lowGain = pow(10, lowGainDB / 20)
        let highGain = 1 - pow(10, highGainDB / 20)
        let highCutoff = parameters.cutoffHz * pow(2, (lowGainDB - 20 * log10(highGain)) / 12)
        let lowPole = exp(-2 * Double.pi * parameters.cutoffHz / sampleRate)
        lowB1 = lowPole
        lowA0 = lowGain * (1 - lowPole)
        let highPole = exp(-2 * Double.pi * min(highCutoff, sampleRate * 0.45) / sampleRate)
        highB1 = highPole
        highA0 = 1 - highGain * (1 - highPole)
        highA1 = -highPole
        gain = 1 / (1 - highGain + lowGain)
    }

    func makeFreshState() -> DSPCrossfeedKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPCrossfeedKernel) {
        lowLeft = source.lowLeft
        lowRight = source.lowRight
        highLeft = source.highLeft
        highRight = source.highRight
        previousLeft = source.previousLeft
        previousRight = source.previousRight
    }

    mutating func reset() {
        lowLeft = 0
        lowRight = 0
        highLeft = 0
        highRight = 0
        previousLeft = 0
        previousRight = 0
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        var lowLeft = lowLeft, lowRight = lowRight
        var highLeft = highLeft, highRight = highRight
        var previousLeft = previousLeft, previousRight = previousRight
        for frame in 0..<frames {
            let base = frame * channels
            let left = samples[base + leftChannel]
            let right = samples[base + rightChannel]
            lowLeft = lowA0 * left + lowB1 * lowLeft
            lowRight = lowA0 * right + lowB1 * lowRight
            highLeft = highA0 * left + highA1 * previousLeft + highB1 * highLeft
            highRight = highA0 * right + highA1 * previousRight + highB1 * highRight
            previousLeft = left
            previousRight = right
            samples[base + leftChannel] = (highLeft + lowRight) * gain
            samples[base + rightChannel] = (highRight + lowLeft) * gain
        }
        self.lowLeft = lowLeft
        self.lowRight = lowRight
        self.highLeft = highLeft
        self.highRight = highRight
        self.previousLeft = previousLeft
        self.previousRight = previousRight
    }
}
