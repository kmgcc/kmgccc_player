import AVFoundation
import CryptoKit
import Foundation

/// Imported impulse responses, stored once by content hash beside the DSP
/// presets. Presets refer to a response by its hash, so the same file
/// imported twice is kept once and a preset never points at a moved file.
nonisolated enum DSPImpulseResponseStore {
    struct Imported: Equatable, Sendable {
        let id: String
        let name: String
        let channelCount: Int
        let durationSeconds: Double
    }

    enum ImportError: LocalizedError {
        case unreadable
        case unsupportedChannelCount(Int)
        case tooLong
        case silent
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取这个音频文件。"
            case .unsupportedChannelCount(let count): "脉冲响应需为单声道、立体声或四声道，此文件有 \(count) 个声道。"
            case .tooLong: "脉冲响应不能超过 10 秒。"
            case .silent: "这个文件没有声音。"
            case .writeFailed: "无法保存脉冲响应。"
            }
        }
    }

    struct Stored: Equatable, Sendable {
        let id: String
        let channelCount: Int
        let sampleRate: Double
        let durationSeconds: Double
    }

    static let maximumSeconds = 10.0

    /// Every stored response, read from file headers only.
    static func storedResponses() -> [Stored] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "caf" }.compactMap { url in
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let format = file.fileFormat
            return Stored(id: url.deletingPathExtension().lastPathComponent,
                          channelCount: Int(format.channelCount), sampleRate: format.sampleRate,
                          durationSeconds: Double(file.length) / format.sampleRate)
        }.sorted { $0.id < $1.id }
    }

    static var directoryURL: URL {
        DSPPresetStore.defaultRootURL.appendingPathComponent("ImpulseResponses", isDirectory: true)
    }

    static func fileURL(id: String) -> URL {
        directoryURL.appendingPathComponent(id).appendingPathExtension("caf")
    }

    static func exists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(id: id).path)
    }

    /// Reads, validates and stores a response; returns its identity.
    static func importFile(at url: URL) throws -> Imported {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0 else { throw ImportError.unreadable }
        let channelCount = Int(file.processingFormat.channelCount)
        guard [1, 2, 4].contains(channelCount) else { throw ImportError.unsupportedChannelCount(channelCount) }
        let sampleRate = file.processingFormat.sampleRate
        guard Double(file.length) / sampleRate <= maximumSeconds else { throw ImportError.tooLong }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ImportError.unreadable
        }
        do { try file.read(into: buffer) } catch { throw ImportError.unreadable }
        guard let channels = buffer.floatChannelData else { throw ImportError.unreadable }
        let frames = Int(buffer.frameLength)

        var hasher = SHA256()
        var rate = sampleRate
        withUnsafeBytes(of: &rate) { hasher.update(bufferPointer: $0) }
        var peak: Float = 0
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pointer, count: frames * MemoryLayout<Float>.size))
            for frame in 0..<frames { peak = max(peak, abs(pointer[frame])) }
        }
        guard peak > 1e-6 else { throw ImportError.silent }
        let id = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let destination = fileURL(id: id)
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                let output = try AVAudioFile(forWriting: destination, settings: settings,
                                             commonFormat: .pcmFormatFloat32, interleaved: false)
                try output.write(from: buffer)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw ImportError.writeFailed
            }
        }
        return Imported(id: id, name: url.deletingPathExtension().lastPathComponent,
                        channelCount: channelCount, durationSeconds: Double(frames) / sampleRate)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [[Double]]] = [:]

    /// The stored response converted to `sampleRate`, one array per channel.
    static func responses(id: String, sampleRate: Double) -> [[Double]]? {
        let key = "\(id)|\(sampleRate)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
        guard let loaded = load(id: id, sampleRate: sampleRate) else { return nil }
        lock.lock()
        if cache.count > 8 { cache.removeAll() }
        cache[key] = loaded
        lock.unlock()
        return loaded
    }

    private static func load(id: String, sampleRate: Double) -> [[Double]]? {
        guard let file = try? AVAudioFile(forReading: fileURL(id: id), commonFormat: .pcmFormatFloat32,
                                          interleaved: false),
              file.length > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil else { return nil }
        let channelCount = Int(source.format.channelCount)
        let converted: AVAudioPCMBuffer
        if abs(source.format.sampleRate - sampleRate) < 0.5 {
            converted = source
        } else {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: source.format.channelCount, interleaved: false),
                  let converter = AVAudioConverter(from: source.format, to: target) else { return nil }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            let capacity = AVAudioFrameCount((Double(source.frameLength) * sampleRate / source.format.sampleRate)
                .rounded(.up)) + 1_024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            let feed = ConverterFeed(buffer: source)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                guard let next = feed.take() else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return next
            }
            guard status != .error, conversionError == nil else { return nil }
            converted = output
        }
        guard let data = converted.floatChannelData else { return nil }
        let frames = Int(converted.frameLength)
        return (0..<channelCount).map { channel in
            (0..<frames).map { Double(data[channel][$0]) }
        }
    }

    /// Hands the whole source buffer to the converter exactly once. The
    /// converter calls its input block synchronously on this thread.
    private final class ConverterFeed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}
