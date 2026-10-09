import AVFoundation

/// Shared crop policy for playback and offline loudness. AVAudioFile may have
/// already consumed an AAC edit list; reconcile lengths before trimming again.
nonisolated struct AACDecodedFrameRange: Equatable, Sendable {
    let startingFrame: Int64
    let frameCount: Int64
    let reason: String
    var isTrimmed: Bool { reason == "trimmed" }

    static func resolve(metadata: AACGaplessInfo?, decodedFrames: Int64, enabled: Bool) -> Self {
        let whole = Self(startingFrame: 0, frameCount: max(0, decodedFrames), reason: "fullFile")
        guard decodedFrames >= 0 else { return whole }
        guard enabled, let metadata, metadata.isAAC, metadata.hasGaplessPadding else { return whole }
        let head = metadata.primingFrames
        let tail = metadata.paddingFrames
        let valid = metadata.validFrames
        guard head >= 0, tail >= 0, valid > 0,
              head <= Int64.max - tail, valid <= Int64.max - head - tail else {
            return Self(startingFrame: 0, frameCount: whole.frameCount, reason: "invalidMetadata")
        }
        let bothDistance = abs(decodedFrames - (valid + head + tail))
        let paddingDistance = abs(decodedFrames - (valid + tail))
        let trimmedDistance = abs(decodedFrames - valid)
        let closest = min(bothDistance, paddingDistance, trimmedDistance)
        guard closest <= 256 else {
            return Self(startingFrame: 0, frameCount: whole.frameCount, reason: "inconsistentMetadata")
        }
        let cropHead: Int64
        let cropTail: Int64
        if closest == bothDistance {
            cropHead = head; cropTail = tail
        } else if closest == paddingDistance {
            cropHead = 0; cropTail = tail
        } else { return whole }
        let count = decodedFrames - cropHead - cropTail
        guard count > 0, count <= Int64(AVAudioFrameCount.max) else {
            return Self(startingFrame: 0, frameCount: whole.frameCount, reason: "invalidRange")
        }
        guard cropHead > 0 || cropTail > 0 else { return whole }
        return Self(startingFrame: cropHead, frameCount: count, reason: "trimmed")
    }
}
