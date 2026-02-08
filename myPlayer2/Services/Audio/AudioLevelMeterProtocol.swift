//
//  AudioLevelMeterProtocol.swift
//  myPlayer2
//
//  TrueMusic - Audio Level Meter Protocol
//

import Foundation

public struct AudioMetrics: Sendable {
    public var rms: Float
    public var peak: Float
    public var db: Float
    public var bands: [Float]
    public var smoothedBands: [Float]
    public var smoothedLevel: Float
    public var bassEnergy: Float
    public var waveform: [Float]
    public var transientLevel: Float
    public var midEnergy: Float
    // Now Playing background dynamics (pre-boost, 0...1).
    public var lowBandDb: Float
    public var lowBandLoudness: Float
    public var kickPulse: Float

    public init(
        rms: Float, peak: Float, db: Float, bands: [Float], smoothedBands: [Float],
        smoothedLevel: Float, bassEnergy: Float, waveform: [Float], transientLevel: Float,
        midEnergy: Float,
        lowBandDb: Float = -160,
        lowBandLoudness: Float = 0,
        kickPulse: Float = 0
    ) {
        self.rms = rms
        self.peak = peak
        self.db = db
        self.bands = bands
        self.smoothedBands = smoothedBands
        self.smoothedLevel = smoothedLevel
        self.bassEnergy = bassEnergy
        self.waveform = waveform
        self.transientLevel = transientLevel
        self.midEnergy = midEnergy
        self.lowBandDb = lowBandDb
        self.lowBandLoudness = lowBandLoudness
        self.kickPulse = kickPulse
    }

    public static let zero = AudioMetrics(
        rms: 0,
        peak: 0,
        db: -160,
        bands: [],
        smoothedBands: [],
        smoothedLevel: 0,
        bassEnergy: 0,
        waveform: [],
        transientLevel: 0,
        midEnergy: 0,
        lowBandDb: -160,
        lowBandLoudness: 0,
        kickPulse: 0
    )
}

@MainActor
public protocol AudioLevelMeterProtocol: AnyObject {
    var normalizedLevel: Float { get }
    var audioMetrics: AudioMetrics { get }
    func start()
    func stop()
}
