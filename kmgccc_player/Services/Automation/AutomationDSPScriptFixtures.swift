import Foundation
import PlayerAutomationProtocol

/// Wire fixture requests stay separate from source drafts and user media.
/// Synthetic settings are safe to retry; supplied PCM is never persisted.
nonisolated struct AutomationDSPScriptFixtures: Sendable {
    let fixtures: [DSPScriptFixture]
    let retryConfiguration: AutomationJSONValue?

    static func parse(_ raw: AutomationJSONValue?, format: DSPAudioFormat) throws -> Self {
        guard let raw else {
            return Self(fixtures: [
                .silence(durationSeconds: 0.1), .impulse(durationSeconds: 0.1, amplitude: 0.5),
                .sine(durationSeconds: 0.25, frequencyHz: min(1000, format.sampleRate * 0.1), amplitude: 0.5),
                .sweep(durationSeconds: 0.5, startFrequencyHz: 20, endFrequencyHz: min(20_000, format.sampleRate * 0.45), amplitude: 0.25),
                .pinkNoise(durationSeconds: 0.25, amplitude: 0.25, seed: 1)
            ], retryConfiguration: .array([]))
        }
        guard case .array(let items) = raw, !items.isEmpty, items.count <= 5 else {
            throw AutomationParameterError.invalidValue("fixtures")
        }
        var fixtures = [DSPScriptFixture]()
        var containsPCM = false
        for item in items {
            guard case .object(let fields) = item, case .string(let kind)? = fields["kind"] else {
                throw AutomationParameterError.invalidValue("fixtures.kind")
            }
            func number(_ key: String, default fallback: Double) throws -> Double {
                guard let raw = fields[key] else { return fallback }
                guard case .number(let value) = raw, value.isFinite else { throw AutomationParameterError.invalidValue("fixtures.\(key)") }
                return value
            }
            let duration = try number("durationSeconds", default: 0.25)
            let amplitude = try number("amplitude", default: 0.25)
            guard duration >= 0.0001, duration <= 2, (-1...1).contains(amplitude) else {
                throw AutomationParameterError.outOfRange("fixtures.durationSeconds/amplitude")
            }
            let allowed: Set<String>
            switch kind {
            case "silence":
                allowed = ["kind", "durationSeconds"]
                fixtures.append(.silence(durationSeconds: duration))
            case "impulse":
                allowed = ["kind", "durationSeconds", "amplitude"]
                fixtures.append(.impulse(durationSeconds: duration, amplitude: amplitude))
            case "sine":
                allowed = ["kind", "durationSeconds", "amplitude", "frequencyHz"]
                let frequency = try number("frequencyHz", default: min(1000, format.sampleRate * 0.1))
                guard frequency > 0, frequency < format.sampleRate / 2 else { throw AutomationParameterError.outOfRange("fixtures.frequencyHz") }
                fixtures.append(.sine(durationSeconds: duration, frequencyHz: frequency, amplitude: amplitude))
            case "sweep":
                allowed = ["kind", "durationSeconds", "amplitude", "startFrequencyHz", "endFrequencyHz"]
                let start = try number("startFrequencyHz", default: 20)
                let end = try number("endFrequencyHz", default: min(20_000, format.sampleRate * 0.45))
                guard start > 0, start < end, end < format.sampleRate / 2 else { throw AutomationParameterError.outOfRange("fixtures.frequencyHz") }
                fixtures.append(.sweep(durationSeconds: duration, startFrequencyHz: start, endFrequencyHz: end, amplitude: amplitude))
            case "pinkNoise":
                allowed = ["kind", "durationSeconds", "amplitude", "seed"]
                let value = try number("seed", default: 1)
                guard let seed = UInt64(exactly: value), seed <= 4_294_967_295 else { throw AutomationParameterError.outOfRange("fixtures.seed") }
                fixtures.append(.pinkNoise(durationSeconds: duration, amplitude: amplitude, seed: seed))
            case "custom":
                allowed = ["kind", "samples"]
                guard case .array(let samples)? = fields["samples"], !samples.isEmpty,
                      samples.count <= 65_536, samples.count % format.channelCount == 0 else {
                    throw AutomationParameterError.invalidValue("fixtures.samples")
                }
                let data = try samples.map { raw -> Float in
                    guard case .number(let value) = raw, value.isFinite, Float(value).isFinite else {
                        throw AutomationParameterError.invalidValue("fixtures.samples")
                    }
                    return Float(value)
                }
                let count = data.count / format.channelCount
                guard Double(count) / format.sampleRate <= 2 else { throw AutomationParameterError.outOfRange("fixtures.samples") }
                fixtures.append(.custom(CanonicalPCM(frames: count, channelCount: format.channelCount,
                    sampleRate: format.sampleRate, data: data)))
                containsPCM = true
            default: throw AutomationParameterError.invalidValue("fixtures.kind")
            }
            guard Set(fields.keys).isSubset(of: allowed) else { throw AutomationParameterError.invalidValue("fixtures") }
        }
        return Self(fixtures: fixtures, retryConfiguration: containsPCM ? nil : raw)
    }
}
