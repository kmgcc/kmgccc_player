import Foundation

nonisolated struct LoudnessMetadataTag: Equatable, Sendable {
    var key: String
    var value: String
}

nonisolated enum LoudnessMetadataParser {
    nonisolated static func parse(
        tags: [LoudnessMetadataTag],
        containerHint: String = "unknown"
    ) -> LoudnessMetadata {
        var diagnostics: [DSPDiagnostic] = []
        let normalized = Dictionary(grouping: tags.compactMap { tag -> (String, String)? in
            guard let key = normalizedKey(tag.key) else { return nil }
            return (key, tag.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }, by: \.0).mapValues { pairs in
            Array(Set(pairs.map(\.1))).sorted()
        }

        func value(_ key: String) -> String? {
            guard let values = normalized[key], values.count == 1 else {
                if (normalized[key]?.count ?? 0) > 1 {
                    diagnostics.append(DSPDiagnostic(
                        code: "audio.loudnessMetadataDuplicate",
                        message: "Conflicting values were found for a normalization tag.",
                        fieldPath: "loudness.metadata.\(key.lowercased())"
                    ))
                }
                return nil
            }
            return values[0]
        }

        func number(_ key: String, range: ClosedRange<Double>) -> Double? {
            guard let raw = value(key) else { return nil }
            guard let parsed = parseDBValue(raw), range.contains(parsed) else {
                diagnostics.append(DSPDiagnostic(
                    code: "audio.loudnessMetadataInvalid",
                    message: "A normalization tag contains a value outside its supported range.",
                    fieldPath: "loudness.metadata.\(key.lowercased())"
                ))
                return nil
            }
            return parsed
        }

        let reference = number("REPLAYGAIN_REFERENCE_LOUDNESS", range: 50...120)
        let replayTrack = number("REPLAYGAIN_TRACK_GAIN", range: -51...51)
        let replayAlbum = number("REPLAYGAIN_ALBUM_GAIN", range: -51...51)
        let replayTrackPeak = number("REPLAYGAIN_TRACK_PEAK", range: 0.000_001...32)
        let replayAlbumPeak = number("REPLAYGAIN_ALBUM_PEAK", range: 0.000_001...32)
        let algorithm = value("REPLAYGAIN_ALGORITHM")

        let hasReplayGainFields = replayTrack != nil || replayAlbum != nil
            || normalized["REPLAYGAIN_TRACK_GAIN"] != nil
            || normalized["REPLAYGAIN_ALBUM_GAIN"] != nil
        // The historical 83/89 dB ReplayGain reference is an SPL convention,
        // not a directly convertible LUFS baseline. Preserve the value and
        // algorithm, but don't use it without an independently validated
        // conversion fixture.
        let replayGainReliable = false
        if hasReplayGainFields {
            diagnostics.append(DSPDiagnostic(
                code: reference == nil
                    ? "audio.loudnessReplayGainReferenceUnknown"
                    : "audio.loudnessReplayGainConversionUnverified",
                message: reference == nil
                    ? "ReplayGain was retained as metadata, but its reference level is unknown."
                    : "ReplayGain was retained as metadata; its SPL reference has no validated LUFS conversion in this scanner.",
                fieldPath: "loudness.metadata.replayGain"
            ))
        }

        let r128Track = parseR128(value("R128_TRACK_GAIN"), key: "R128_TRACK_GAIN", diagnostics: &diagnostics)
        let r128Album = parseR128(value("R128_ALBUM_GAIN"), key: "R128_ALBUM_GAIN", diagnostics: &diagnostics)
        let outputGain = parseR128(value("OPUSHEAD_OUTPUT_GAIN_Q78"), key: "OPUSHEAD_OUTPUT_GAIN_Q78", diagnostics: &diagnostics)
        let hasR128Fields = r128Track != nil || r128Album != nil
            || normalized["R128_TRACK_GAIN"] != nil
            || normalized["R128_ALBUM_GAIN"] != nil

        let isOpus = ["opus", "ogg-opus", "audio/opus"].contains(containerHint.lowercased())
        let r128Reliable = hasR128Fields
            && (r128Track != nil || r128Album != nil)
            && containerHint.lowercased() == "flac"
        if isOpus && hasR128Fields {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessOpusGainBaselineUnknown",
                message: "Opus R128 tags were retained, but the decoder's OpusHead output-gain baseline is unverified.",
                fieldPath: "loudness.metadata.r128"
            ))
        } else if hasR128Fields && !r128Reliable {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessR128BaselineUnknown",
                message: "R128 tags were retained, but this container does not have a verified decoder gain baseline.",
                fieldPath: "loudness.metadata.r128"
            ))
        }

        return LoudnessMetadata(
            replayGainTrackDB: replayTrack,
            replayGainAlbumDB: replayAlbum,
            replayGainTrackPeak: replayTrackPeak,
            replayGainAlbumPeak: replayAlbumPeak,
            replayGainReferenceDB: reference,
            replayGainReferenceLUFS: nil,
            replayGainAlgorithm: algorithm,
            replayGainIsReliable: replayGainReliable,
            r128TrackGainDB: r128Track,
            r128AlbumGainDB: r128Album,
            opusOutputGainDB: outputGain,
            r128IsReliable: r128Reliable,
            containerHint: containerHint,
            diagnostics: diagnostics
        )
    }

    nonisolated static func normalizedKey(_ raw: String) -> String? {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "TXXX:", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "----:", with: "", options: [.caseInsensitive])
        guard !key.isEmpty else { return nil }
        let components = key.split(whereSeparator: { $0 == "." || $0 == ":" || $0 == "/" })
        guard let final = components.last else { return nil }
        return String(final).uppercased()
    }

    private nonisolated static func parseDBValue(_ raw: String) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix("db") {
            value = String(value.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let parsed = Double(value), parsed.isFinite else { return nil }
        return parsed
    }

    private nonisolated static func parseR128(
        _ raw: String?,
        key: String,
        diagnostics: inout [DSPDiagnostic]
    ) -> Double? {
        guard let raw else { return nil }
        guard !raw.isEmpty,
              raw.utf8.count <= 6,
              raw.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || byte == 43 || byte == 45
              }),
              let integer = Int(raw),
              (-32_768...32_767).contains(integer) else {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessMetadataInvalid",
                message: "An R128 gain tag must be a signed 16-bit Q7.8 decimal integer.",
                fieldPath: "loudness.metadata.\(key.lowercased())"
            ))
            return nil
        }
        return Double(integer) / 256
    }
}
