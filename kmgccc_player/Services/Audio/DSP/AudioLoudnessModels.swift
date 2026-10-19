import Foundation

nonisolated enum LoudnessMeasurementStatus: String, Codable, Equatable, Sendable {
    case available
    case tooShort
    case silence
    case unsupportedLayout
    case unsupportedFormat
    case resourceLimit
}

/// Distribution of 100 ms-step, 400 ms-window K-weighted block energies in
/// 0.1 LU bins. Album loudness merges the members' histograms and gates the
/// result, so no raw block energies are kept long term. Only non-empty bins
/// are stored, which keeps a typical record to a few kilobytes.
nonisolated struct LoudnessEnergyHistogram: Codable, Equatable, Sendable {
    nonisolated static let minimumLUFS = -70.0
    nonisolated static let maximumLUFS = 50.0
    nonisolated static let binWidthLU = 0.1
    nonisolated static let binCount = 1_200

    var counts: [UInt32]

    private enum CodingKeys: String, CodingKey {
        case bins
    }

    nonisolated init() {
        counts = Array(repeating: 0, count: Self.binCount)
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counts = Array(repeating: 0, count: Self.binCount)
        for pair in try container.decode([[UInt32]].self, forKey: .bins)
        where pair.count == 2 && Int(pair[0]) < Self.binCount {
            counts[Int(pair[0])] = pair[1]
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nonEmptyBins.map { [UInt32($0.index), $0.count] }, forKey: .bins)
    }

    nonisolated var nonEmptyBins: [(index: Int, count: UInt32)] {
        counts.indices.compactMap { counts[$0] > 0 ? ($0, counts[$0]) : nil }
    }

    nonisolated var blockCount: Int64 {
        counts.reduce(Int64(0)) { $0 + Int64($1) }
    }

    @discardableResult
    nonisolated mutating func add(linearEnergy: Double) -> Bool {
        guard linearEnergy.isFinite, linearEnergy > 0 else { return true }
        let level = -0.691 + 10 * log10(linearEnergy)
        guard level > Self.minimumLUFS else { return true }
        guard level < Self.maximumLUFS else { return false }
        let index = Int((level - Self.minimumLUFS) / Self.binWidthLU)
        guard counts.indices.contains(index), counts[index] < UInt32.max else { return false }
        counts[index] += 1
        return true
    }

    @discardableResult
    nonisolated mutating func merge(_ other: LoudnessEnergyHistogram) -> Bool {
        guard counts.count == Self.binCount, other.counts.count == Self.binCount else { return false }
        for index in counts.indices {
            guard counts[index] <= UInt32.max - other.counts[index] else { return false }
        }
        for index in counts.indices {
            counts[index] += other.counts[index]
        }
        return true
    }
}

/// Measurement values and a compact block-energy distribution retained so
/// album results can be gated together without averaging per-track LUFS values.
nonisolated struct LoudnessMeasurement: Codable, Equatable, Sendable {
    /// 2: exact block gating, BS.1770 Annex 2 true peak, sparse histogram.
    /// 3: a decode that ends shortly before the declared length is measured.
    static let currentAnalyzerVersion = 3
    static let currentDecoderRuleVersion = 1
    /// Changes whenever the decoded-frame crop policy changes. The first
    /// scanner uses the renderer's reconciled decoded-frame range.
    static let currentTrimPolicyVersion = 3

    var status: LoudnessMeasurementStatus
    var format: DSPAudioFormat
    var validStartFrame: Int64
    var validEndFrame: Int64
    var analyzerVersion: Int
    var decoderRuleVersion: Int
    var trimPolicyVersion: Int
    var analysisFrameRange: String
    var playbackAACGaplessTrimEnabled: Bool
    var integratedLUFS: Double?
    var samplePeakDBFS: Double?
    var truePeakDBTP: Double?
    var gatedBlockEnergyHistogram: LoudnessEnergyHistogram
    var gatedBlockCount: Int64
    var blockFrames: Int
    var blockStepFrames: Int
    var confidence: Double
    var diagnostics: [DSPDiagnostic]

    nonisolated var analyzedFrameCount: Int64 {
        max(0, validEndFrame - validStartFrame)
    }

    nonisolated var isUsable: Bool {
        status == .available && integratedLUFS?.isFinite == true && gatedBlockCount > 0
    }
}

nonisolated struct LoudnessFileIdentity: Codable, Equatable, Sendable {
    var pathDigest: String
    var resourceIdentifier: String?
    var fileSize: Int64
    var modificationTimeNanoseconds: Int64
}

/// Normalization tags found in the file. They are kept for diagnostics only;
/// sources disagree on reference level and reliability, so playback gain is
/// always computed from the App's own measurement.
nonisolated struct LoudnessMetadata: Codable, Equatable, Sendable {
    static let currentParserVersion = 1
    var replayGainTrackDB: Double?
    var replayGainAlbumDB: Double?
    var replayGainTrackPeak: Double?
    var replayGainAlbumPeak: Double?
    var replayGainReferenceDB: Double?
    /// A separately verified LUFS reference. Classic ReplayGain SPL values
    /// are never inferred into this field.
    var replayGainReferenceLUFS: Double?
    var replayGainAlgorithm: String?
    var replayGainIsReliable: Bool

    var r128TrackGainDB: Double?
    var r128AlbumGainDB: Double?
    var opusOutputGainDB: Double?
    var r128IsReliable: Bool

    var containerHint: String
    var diagnostics: [DSPDiagnostic]

    nonisolated static let empty = LoudnessMetadata(
        replayGainTrackDB: nil,
        replayGainAlbumDB: nil,
        replayGainTrackPeak: nil,
        replayGainAlbumPeak: nil,
        replayGainReferenceDB: nil,
        replayGainReferenceLUFS: nil,
        replayGainAlgorithm: nil,
        replayGainIsReliable: false,
        r128TrackGainDB: nil,
        r128AlbumGainDB: nil,
        opusOutputGainDB: nil,
        r128IsReliable: false,
        containerHint: "unknown",
        diagnostics: []
    )
}

nonisolated struct LoudnessTrackRecord: Codable, Equatable, Sendable, Identifiable {
    static let currentCacheRecordVersion = 3

    var id: UUID
    var cacheRecordVersion: Int
    var metadataParserVersion: Int
    var playbackAACGaplessTrimEnabled: Bool
    var fileIdentity: LoudnessFileIdentity
    var measurement: LoudnessMeasurement?
    var metadata: LoudnessMetadata
    var analyzedAt: Date

    nonisolated var analyzerVersion: Int {
        measurement?.analyzerVersion ?? LoudnessMeasurement.currentAnalyzerVersion
    }
}

nonisolated struct LoudnessGainDecision: Codable, Equatable, Sendable {
    nonisolated enum Source {
        nonisolated static let track = "measured.track"
        nonisolated static let album = "measured.album"
        nonisolated static let disabled = "disabled"
        nonisolated static let missing = "unity.missing"
        nonisolated static let invalid = "unity.invalidMeasurement"
    }

    var gainDB: Double
    var source: String
    var peakBasis: String
    var measuredLUFS: Double?
    var diagnostics: [DSPDiagnostic]

    nonisolated init(
        gainDB: Double,
        source: String,
        peakBasis: String,
        measuredLUFS: Double? = nil,
        diagnostics: [DSPDiagnostic] = []
    ) {
        self.gainDB = gainDB
        self.source = source
        self.peakBasis = peakBasis
        self.measuredLUFS = measuredLUFS
        self.diagnostics = diagnostics
    }

    nonisolated var linearGain: Double { pow(10, gainDB / 20) }
    nonisolated var isMeasured: Bool { source.hasPrefix("measured.") }

    nonisolated static func unity(
        source: String = Source.missing,
        diagnostic: DSPDiagnostic? = nil
    ) -> LoudnessGainDecision {
        LoudnessGainDecision(
            gainDB: 0,
            source: source,
            peakBasis: "unknown",
            diagnostics: diagnostic.map { [$0] } ?? []
        )
    }
}

/// Fixed-gain normalization from the App's own BS.1770 measurements. A gain
/// never raises the measured true peak above the fixed ceiling; no limiter is
/// used, so a quiet track may stay below the target rather than lose dynamics.
nonisolated enum LoudnessGainSelector {
    /// Margin added to a sample peak when no true peak is available.
    private static let samplePeakMarginDB = 2.0

    nonisolated static func trackGain(
        configuration: AudioLoudnessConfiguration,
        measurement: LoudnessMeasurement?
    ) -> LoudnessGainDecision {
        guard configuration.enabled else { return .unity(source: LoudnessGainDecision.Source.disabled) }
        guard let measurement, measurement.isUsable, let integrated = measurement.integratedLUFS else {
            return .unity(diagnostic: DSPDiagnostic(
                code: "audio.loudnessUnavailable",
                message: "No current loudness measurement is available.",
                fieldPath: "loudness.measurement",
                retryable: true
            ))
        }
        return normalizedGain(
            configuration: configuration,
            measuredLUFS: integrated,
            truePeakDBTP: measurement.truePeakDBTP,
            samplePeakDBFS: measurement.samplePeakDBFS,
            source: LoudnessGainDecision.Source.track,
            inheritedDiagnostics: []
        )
    }

    /// One gain for a whole album. Members' block histograms are merged and
    /// gated together (never an average of per-track LUFS), and the loudest
    /// member's true peak bounds the boost. Members that could not be
    /// measured are left out. Returns nil when no member is usable.
    nonisolated static func albumGain(
        configuration: AudioLoudnessConfiguration,
        measurements: [LoudnessMeasurement]
    ) -> LoudnessGainDecision? {
        guard configuration.enabled else { return .unity(source: LoudnessGainDecision.Source.disabled) }
        let usable = measurements.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }
        var histogram = LoudnessEnergyHistogram()
        for measurement in usable {
            guard histogram.merge(measurement.gatedBlockEnergyHistogram) else { return nil }
        }
        let integrated = usable.count == 1
            ? usable[0].integratedLUFS
            : LoudnessAnalyzer.integratedLUFS(from: histogram)
        guard let integrated else { return nil }
        let truePeaks = usable.compactMap(\.truePeakDBTP)
        return normalizedGain(
            configuration: configuration,
            measuredLUFS: integrated,
            truePeakDBTP: truePeaks.count == usable.count ? truePeaks.max() : nil,
            samplePeakDBFS: usable.compactMap(\.samplePeakDBFS).max(),
            source: LoudnessGainDecision.Source.album,
            inheritedDiagnostics: []
        )
    }

    private nonisolated static func normalizedGain(
        configuration: AudioLoudnessConfiguration,
        measuredLUFS: Double,
        truePeakDBTP: Double?,
        samplePeakDBFS: Double?,
        source: String,
        inheritedDiagnostics: [DSPDiagnostic]
    ) -> LoudnessGainDecision {
        let target = finiteTarget(configuration.targetLUFS)
        let requested = target - measuredLUFS
        let peakBasis: String
        let conservativePeak: Double
        if let truePeakDBTP, truePeakDBTP.isFinite {
            peakBasis = "truePeak"
            conservativePeak = truePeakDBTP
        } else if let samplePeakDBFS, samplePeakDBFS.isFinite {
            peakBasis = "samplePeak"
            conservativePeak = samplePeakDBFS + samplePeakMarginDB
        } else {
            peakBasis = "unknown"
            conservativePeak = samplePeakMarginDB
        }
        var decision = boundedGain(
            requested,
            peakBasis: peakBasis,
            peakDB: conservativePeak,
            configuration: configuration,
            source: source,
            inheritedDiagnostics: inheritedDiagnostics
        )
        decision.measuredLUFS = measuredLUFS
        return decision
    }

    private nonisolated static func boundedGain(
        _ requestedGainDB: Double,
        peakBasis: String,
        peakDB: Double,
        configuration: AudioLoudnessConfiguration,
        source: String,
        inheritedDiagnostics: [DSPDiagnostic]
    ) -> LoudnessGainDecision {
        guard requestedGainDB.isFinite, peakDB.isFinite else {
            return .unity(
                source: LoudnessGainDecision.Source.invalid,
                diagnostic: DSPDiagnostic(
                    code: "audio.loudnessInvalidMeasurement",
                    message: "The loudness or peak data is not finite, so no gain was applied.",
                    fieldPath: "loudness.measurement"
                )
            )
        }

        let maxBoost = configuration.maxBoostDB
        let maxAttenuation = configuration.maxAttenuationDB
        let peakAllowedGain = configuration.truePeakCeilingDBTP - peakDB
        let requestedAfterBoostLimit = min(requestedGainDB, maxBoost)
        let peakSafeGain = min(requestedAfterBoostLimit, peakAllowedGain)
        let applied: Double
        var diagnostics = inheritedDiagnostics

        if peakAllowedGain < -maxAttenuation {
            applied = peakSafeGain
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessPeakAttenuationConflict",
                message: "The peak ceiling requires more attenuation than the fixed limit; peak safety takes priority.",
                fieldPath: "loudness.maxAttenuationDB"
            ))
        } else {
            applied = max(peakSafeGain, -maxAttenuation)
        }

        if peakSafeGain < requestedAfterBoostLimit {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessPeakLimited",
                message: "The true-peak ceiling limits the requested normalization gain.",
                fieldPath: "loudness.truePeakCeilingDBTP"
            ))
        } else if requestedGainDB > maxBoost {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessBoostLimited",
                message: "The requested normalization exceeds the fixed maximum boost.",
                fieldPath: "loudness.maxBoostDB"
            ))
        }

        return LoudnessGainDecision(
            gainDB: applied,
            source: source,
            peakBasis: peakBasis,
            diagnostics: diagnostics
        )
    }

    private nonisolated static func finiteTarget(_ value: Double) -> Double {
        value.isFinite
            ? min(max(value, AudioLoudnessConfiguration.targetRange.lowerBound), AudioLoudnessConfiguration.targetRange.upperBound)
            : AudioLoudnessConfiguration.defaultTargetLUFS
    }
}
