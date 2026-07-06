//
//  GaplessProbe.swift
//  myPlayer2
//
//  DEBUG-only boundary diagnostics for gapless playback.
//
//  Measures the audio content at the seam between the currently-playing item's
//  tail and the prefetched next item's head, to tell whether an audible gap at a
//  gapless join comes from the engine schedule (it does not — see the
//  `[GaplessBoundary] diffFrames=0` invariant log) or from the files themselves
//  (encoder delay / padding / leading silence).
//
//  It reads only ~50ms per side, OFF the main thread, from independent file
//  handles — never the player node's own `AVAudioFile`. It performs no trimming
//  and does not alter playback in any way.
//

import AVFoundation
import Foundation

/// `nonisolated` so it can run off the main actor (the app target defaults to
/// MainActor isolation). All work is pure / file-local; it touches no shared
/// mutable state.
nonisolated enum GaplessProbe {

    private struct EdgeAnalysis {
        let rms20ms: Float
        let rms50ms: Float
        let peak50ms: Float
        let nearSilentMs: Double
    }

    /// Amplitude at/under which a sample counts as "near silent" when measuring
    /// leading/trailing silence (~ -66 dBFS). Catches true digital silence and
    /// encoder padding without flagging quiet musical passages.
    private static let nearSilentThreshold: Float = 0.0005

    /// Analyze the current item's tail and the next item's head and log the
    /// result. Safe to call from any thread; intended to be dispatched off-main.
    static func run(
        currentURL: URL,
        currentTailEndFrame: AVAudioFramePosition,
        currentTrackID: UUID,
        nextURL: URL,
        nextTrackID: UUID
    ) {
        let tail = analyze(url: currentURL, edge: .tail(endFrame: currentTailEndFrame))
        let head = analyze(url: nextURL, edge: .head)

        guard let tail, let head else {
            Log.info(
                "[GaplessProbe] unavailable currentTailOK=\(tail != nil) nextHeadOK=\(head != nil) current=\(currentTrackID.uuidString.prefix(8)) next=\(nextTrackID.uuidString.prefix(8))",
                category: .audio
            )
            return
        }

        Log.info(
            "[GaplessProbe] current=\(currentTrackID.uuidString.prefix(8)) next=\(nextTrackID.uuidString.prefix(8)) "
                + "currentTail20msRMS=\(f(tail.rms20ms)) currentTail50msRMS=\(f(tail.rms50ms)) currentTail50msPeak=\(f(tail.peak50ms)) "
                + "nextHead20msRMS=\(f(head.rms20ms)) nextHead50msRMS=\(f(head.rms50ms)) nextHead50msPeak=\(f(head.peak50ms)) "
                + "currentTailNearSilentMs=\(fms(tail.nearSilentMs)) nextHeadNearSilentMs=\(fms(head.nearSilentMs))",
            category: .audio
        )
    }

    private enum Edge {
        case tail(endFrame: AVAudioFramePosition)
        case head
    }

    private static func analyze(url: URL, edge: Edge) -> EdgeAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return nil }

        let total = file.length
        guard total > 0 else { return nil }

        let window50 = min(total, AVAudioFramePosition(0.05 * sampleRate))
        guard window50 > 0 else { return nil }

        let startFrame: AVAudioFramePosition
        switch edge {
        case .head:
            startFrame = 0
        case .tail(let endFrame):
            let clampedEnd = max(0, min(endFrame, total))
            startFrame = max(0, clampedEnd - window50)
        }

        file.framePosition = startFrame
        let capacity = AVAudioFrameCount(window50)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        do {
            try file.read(into: buffer, frameCount: capacity)
        } catch {
            return nil
        }

        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }

        let window20 = max(1, min(n, Int(0.02 * sampleRate)))
        let rms50 = rms(channel, from: 0, to: n)
        let peak50 = peak(channel, from: 0, to: n)

        let rms20: Float
        let nearSilentFrames: Int
        switch edge {
        case .head:
            rms20 = rms(channel, from: 0, to: window20)
            nearSilentFrames = leadingNearSilentFrames(channel, count: n)
        case .tail:
            rms20 = rms(channel, from: n - window20, to: n)
            nearSilentFrames = trailingNearSilentFrames(channel, count: n)
        }

        return EdgeAnalysis(
            rms20ms: rms20,
            rms50ms: rms50,
            peak50ms: peak50,
            nearSilentMs: Double(nearSilentFrames) / sampleRate * 1000
        )
    }

    private static func rms(_ p: UnsafePointer<Float>, from: Int, to: Int) -> Float {
        guard to > from else { return 0 }
        var sum: Float = 0
        for i in from..<to { sum += p[i] * p[i] }
        return (sum / Float(to - from)).squareRoot()
    }

    private static func peak(_ p: UnsafePointer<Float>, from: Int, to: Int) -> Float {
        guard to > from else { return 0 }
        var m: Float = 0
        for i in from..<to { m = max(m, abs(p[i])) }
        return m
    }

    private static func leadingNearSilentFrames(_ p: UnsafePointer<Float>, count: Int) -> Int {
        var i = 0
        while i < count, abs(p[i]) <= nearSilentThreshold { i += 1 }
        return i
    }

    private static func trailingNearSilentFrames(_ p: UnsafePointer<Float>, count: Int) -> Int {
        var i = count - 1
        var c = 0
        while i >= 0, abs(p[i]) <= nearSilentThreshold {
            c += 1
            i -= 1
        }
        return c
    }

    private static func f(_ v: Float) -> String { String(format: "%.5f", v) }
    private static func fms(_ v: Double) -> String { String(format: "%.1f", v) }
}
