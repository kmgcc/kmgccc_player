import Foundation

nonisolated enum LoudnessMeasurementStatus: String, Codable, Equatable, Sendable {
    case available
    case tooShort
    case silence
    case unsupportedLayout
    case unsupportedFormat
    case resourceLimit
}

/// Fixed-size distribution of 100 ms-step, 400 ms-window K-weighted block
/// energies. Bin counts are merged across an album, then converted back to
/// representative linear energies for the two gating passes.
nonisolated struct LoudnessEnergyHistogram: Codable, Equatable, Sendable {
    nonisolated static let minimumLUFS = -70.0
    nonisolated static let maximumLUFS = 50.0
    nonisolated static let binWidthLU = 0.1
    nonisolated static let binCount = 1_200

    var counts: [UInt32]

    nonisolated init() {
        counts = Array(repeating: 0, count: Self.binCount)
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
    static let currentAnalyzerVersion = 1
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
}

nonisolated struct LoudnessFileIdentity: Codable, Equatable, Sendable {
    var pathDigest: String
    var resourceIdentifier: String?
    var fileSize: Int64
    var modificationTimeNanoseconds: Int64
}

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
    var gainDB: Double
    var source: String
    var peakBasis: String
    var diagnostics: [DSPDiagnostic]

    nonisolated static func unity(
        source: String = "unity",
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

nonisolated enum LoudnessGainSelector {
    private static let metadataPeakMarginDB = 2.0
    private static let r128ReferenceLUFS = -23.0

    nonisolated static func trackGain(
        configuration: AudioLoudnessConfiguration,
        measurement: LoudnessMeasurement?,
        metadata: LoudnessMetadata? = nil
    ) -> LoudnessGainDecision {
        guard configuration.enabled else {
            return .unity(source: "disabled")
        }

        if let measurement,
           measurement.status == .available,
           let integrated = measurement.integratedLUFS,
           integrated.isFinite {
            return normalizedGain(
                configuration: configuration,
                measuredLUFS: integrated,
                truePeakDBTP: measurement.truePeakDBTP,
                samplePeakDBFS: measurement.samplePeakDBFS,
                source: "measured.bs1770",
                inheritedDiagnostics: measurement.diagnostics + (metadata?.diagnostics ?? [])
            )
        }

        if let metadata, metadata.r128IsReliable,
           let tagGain = metadata.r128TrackGainDB,
           tagGain.isFinite {
            let target = finiteTarget(configuration.targetLUFS)
            let gain = tagGain + target - r128ReferenceLUFS
            return boundedMetadataGain(
                gain,
                peakRatio: metadata.replayGainTrackPeak,
                configuration: configuration,
                source: "metadata.r128",
                inheritedDiagnostics: metadata.diagnostics
            )
        }

        if let metadata, metadata.replayGainIsReliable,
           let gain = metadata.replayGainTrackDB,
           gain.isFinite {
            let referenceLUFS = metadata.replayGainReferenceLUFS
            guard let referenceLUFS, referenceLUFS.isFinite else {
                return .unity(
                    source: "unity.metadataReferenceUnknown",
                    diagnostic: DSPDiagnostic(
                        code: "audio.loudnessReplayGainReferenceUnknown",
                        message: "The normalization tag reference cannot be converted to an integrated loudness target.",
                        fieldPath: "loudness.metadata.replayGainReference"
                    )
                )
            }
            var diagnostics = metadata.diagnostics
            diagnostics.append(DSPDiagnostic(
                code: "loudness.replayGainReference",
                message: "ReplayGain was converted from its explicit reference level to the selected integrated loudness target.",
                fieldPath: "loudness.metadata.replayGain"
            ))
            return boundedMetadataGain(
                gain + finiteTarget(configuration.targetLUFS) - referenceLUFS,
                peakRatio: metadata.replayGainTrackPeak,
                configuration: configuration,
                source: "metadata.replaygain",
                inheritedDiagnostics: diagnostics
            )
        }

        var diagnostics = metadata?.diagnostics ?? []
        diagnostics.append(DSPDiagnostic(
            code: "audio.loudnessUnavailable",
            message: "No current loudness measurement or reliable normalization tag is available.",
            fieldPath: "loudness.measurement",
            retryable: true
        ))
        return LoudnessGainDecision(
            gainDB: 0,
            source: "unity.missing",
            peakBasis: "unknown",
            diagnostics: diagnostics
        )
    }

    nonisolated static func albumGain(
        configuration: AudioLoudnessConfiguration,
        measurements: [LoudnessMeasurement],
        metadata: [LoudnessMetadata] = []
    ) -> LoudnessGainDecision {
        guard configuration.enabled else {
            return .unity(source: "disabled")
        }

        let hasCompleteMeasurements = !measurements.isEmpty
            && measurements.allSatisfy {
                $0.status == .available
                    && $0.integratedLUFS?.isFinite == true
                    && $0.gatedBlockCount > 0
            }
        if hasCompleteMeasurements {
            var histogram = LoudnessEnergyHistogram()
            for measurement in measurements {
                guard histogram.merge(measurement.gatedBlockEnergyHistogram) else {
                    return missingAlbumDecision()
                }
            }
            guard let integrated = LoudnessAnalyzer.integratedLUFS(from: histogram) else {
                return missingAlbumDecision()
            }
            let peaks = measurements.compactMap(\.truePeakDBTP)
            let samplePeaks = measurements.compactMap(\.samplePeakDBFS)
            let inherited = measurements.flatMap(\.diagnostics)
            return normalizedGain(
                configuration: configuration,
                measuredLUFS: integrated,
                truePeakDBTP: peaks.max(),
                samplePeakDBFS: samplePeaks.max(),
                source: "measured.album",
                inheritedDiagnostics: inherited
            )
        }

        if !metadata.isEmpty,
           metadata.allSatisfy({ $0.replayGainIsReliable && $0.replayGainAlbumDB?.isFinite == true }),
           let referenceLUFS = metadata.first?.replayGainReferenceLUFS,
           metadata.allSatisfy({ $0.replayGainReferenceLUFS == referenceLUFS }),
           let albumGain = metadata.first?.replayGainAlbumDB,
           metadata.allSatisfy({ abs(($0.replayGainAlbumDB ?? .infinity) - albumGain) < 0.01 }) {
            guard referenceLUFS.isFinite else {
                return missingAlbumDecision()
            }
            return boundedMetadataGain(
                albumGain + finiteTarget(configuration.targetLUFS) - referenceLUFS,
                peakRatio: metadata.compactMap(\.replayGainAlbumPeak).max(),
                configuration: configuration,
                source: "metadata.replaygain.album",
                inheritedDiagnostics: metadata.flatMap(\.diagnostics)
            )
        }

        if !metadata.isEmpty,
           metadata.allSatisfy({ $0.r128IsReliable && $0.r128AlbumGainDB?.isFinite == true }),
           let albumGain = metadata.first?.r128AlbumGainDB,
           metadata.allSatisfy({ abs(($0.r128AlbumGainDB ?? .infinity) - albumGain) < 0.01 }) {
            let target = finiteTarget(configuration.targetLUFS)
            return boundedMetadataGain(
                albumGain + target - r128ReferenceLUFS,
                peakRatio: metadata.compactMap(\.replayGainAlbumPeak).max(),
                configuration: configuration,
                source: "metadata.r128.album",
                inheritedDiagnostics: metadata.flatMap(\.diagnostics)
            )
        }

        return missingAlbumDecision()
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
            conservativePeak = samplePeakDBFS + metadataPeakMarginDB
        } else {
            peakBasis = "unknown"
            conservativePeak = metadataPeakMarginDB
        }
        return boundedGain(
            requested,
            peakBasis: peakBasis,
            peakDB: conservativePeak,
            configuration: configuration,
            source: source,
            inheritedDiagnostics: inheritedDiagnostics
        )
    }

    private nonisolated static func boundedMetadataGain(
        _ requested: Double,
        peakRatio: Double?,
        configuration: AudioLoudnessConfiguration,
        source: String,
        inheritedDiagnostics: [DSPDiagnostic]
    ) -> LoudnessGainDecision {
        let peakDB: Double?
        if let peakRatio, peakRatio.isFinite, peakRatio > 0 {
            peakDB = 20 * log10(peakRatio) + metadataPeakMarginDB
        } else {
            peakDB = nil
        }
        return boundedGain(
            requested,
            peakBasis: peakDB == nil ? "unknown" : "samplePeak",
            peakDB: peakDB ?? metadataPeakMarginDB,
            configuration: configuration,
            source: source,
            inheritedDiagnostics: inheritedDiagnostics
        )
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
                source: "unity.invalidMeasurement",
                diagnostic: DSPDiagnostic(
                    code: "audio.loudnessInvalidMeasurement",
                    message: "The loudness or peak data is not finite, so no gain was applied.",
                    fieldPath: "loudness.measurement"
                )
            )
        }

        let maxBoost = finiteLimit(configuration.maxBoostDB, fallback: 0, lowerBound: 0)
        let maxAttenuation = finiteLimit(configuration.maxAttenuationDB, fallback: 0, lowerBound: 0)
        let ceiling = configuration.truePeakCeilingDBTP.isFinite
            ? configuration.truePeakCeilingDBTP
            : -1
        let peakAllowedGain = ceiling - peakDB
        let requestedAfterBoostLimit = min(requestedGainDB, maxBoost)
        let peakSafeGain = min(requestedAfterBoostLimit, peakAllowedGain)
        let applied: Double
        var diagnostics = inheritedDiagnostics

        if peakAllowedGain < -maxAttenuation {
            applied = peakSafeGain
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessPeakAttenuationConflict",
                message: "The peak ceiling requires more attenuation than the configured limit; peak safety takes priority.",
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
                message: "The requested normalization exceeds the configured maximum boost.",
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

    private nonisolated static func missingAlbumDecision() -> LoudnessGainDecision {
        .unity(
            source: "unity.albumIncomplete",
            diagnostic: DSPDiagnostic(
                code: "audio.loudnessAlbumUnavailable",
                message: "A complete album measurement is required before applying album normalization.",
                fieldPath: "loudness.album",
                retryable: true
            )
        )
    }

    private nonisolated static func finiteTarget(_ value: Double) -> Double {
        value.isFinite ? min(max(value, -60), 6) : -18
    }

    private nonisolated static func finiteLimit(
        _ value: Double,
        fallback: Double,
        lowerBound: Double
    ) -> Double {
        value.isFinite ? max(value, lowerBound) : fallback
    }
}
