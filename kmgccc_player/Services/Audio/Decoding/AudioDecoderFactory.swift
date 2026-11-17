import AudioToolbox
import AVFoundation
import Darwin
import Foundation

nonisolated enum AudioDecodingError: Error, LocalizedError {
    case unavailable
    case failed(String)
    case invalidRange
    var errorDescription: String? {
        switch self {
        case .unavailable: return "音频解码组件不可用"
        case .failed(let message): return "音频读取失败：\(message)"
        case .invalidRange: return "分轨范围超出音频内容"
        }
    }
}

nonisolated struct AudioDecoderInfo: Decodable, Sendable {
    struct ProgramTrack: Decodable, Sendable {
        let number: Int
        let title: String
        let artist: String
        let start: Int64
        let length: Int64
    }
    let sampleRate: Double
    let sourceSampleRate: Double
    let channels: Int
    let bitDepth: Int
    let frames: Int64
    let codec: String
    var title: String?
    var artist: String?
    var album: String?
    var album_artist: String?
    var lyrics: String?
    var cuesheet: String?
    var date: String?
    var track: String?
    var musicbrainz_albumid: String?
    var compilation: String?
    var artwork: String?
    var lossless: Bool?
    var channelMask: UInt64?
    var programStart: Int64?
    var area: Int?
    var availableAreas: [Int]?
    var tracks: [ProgramTrack]?
    var duration: Double { Double(frames) / sampleRate }
    var audioProperties: TrackAudioProperties {
        var properties = TrackAudioProperties(codec: codec.uppercased(), sampleRateHz: Int(sourceSampleRate),
            bitDepth: bitDepth > 0 ? bitDepth : nil, channelCount: channels)
        properties.decodedSampleRateHz = Int(sampleRate)
        properties.isLossless = lossless
        return properties
    }
}

nonisolated final class AudioCodecRuntime: @unchecked Sendable {
    typealias Open = @convention(c) (UnsafePointer<CChar>, Int32, Int32) -> UnsafeMutableRawPointer?
    typealias Info = @convention(c) (UnsafeMutableRawPointer) -> UnsafePointer<CChar>
    typealias Read = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Float>, Int32) -> Int32
    typealias Seek = @convention(c) (UnsafeMutableRawPointer, Int64) -> Int32
    typealias Close = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Failure = @convention(c) () -> UnsafePointer<CChar>
    static let shared: Result<AudioCodecRuntime, Error> = Result { try AudioCodecRuntime() }
    let open: Open
    let info: Info
    let read: Read
    let seek: Seek
    let close: Close
    let failure: Failure
    private let library: UnsafeMutableRawPointer

    private init() throws {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("AudioCodecs/libkmg_audio.dylib"),
              let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw AudioDecodingError.unavailable }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw AudioDecodingError.unavailable }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            open = try symbol("kmg_audio_open", as: Open.self)
            info = try symbol("kmg_audio_info", as: Info.self)
            read = try symbol("kmg_audio_read", as: Read.self)
            seek = try symbol("kmg_audio_seek", as: Seek.self)
            close = try symbol("kmg_audio_close", as: Close.self)
            failure = try symbol("kmg_audio_error", as: Failure.self)
            self.library = library
        } catch {
            dlclose(library)
            throw error
        }
    }
    deinit { dlclose(library) }
    func error() -> Error { AudioDecodingError.failed(String(cString: failure())) }
}

/// The renderer's serial queue is the sole consumer after preparation hands off.
nonisolated final class AudioDecoderResource: @unchecked Sendable {
    let info: AudioDecoderInfo
    let provider: any RendererPCMProvider
    let sourceFile: AVAudioFile?
    let processingFormat: AVAudioFormat
    private var backingResource: AudioDecoderResource?
    var length: AVAudioFramePosition { provider.totalFrames }
    var sampleRate: Double { provider.sourceSampleRate }
    var fileFormat: AVAudioFormat { sourceFile?.fileFormat ?? processingFormat }
    private var readPosition: Int64 = 0
    private var readNeedsSeek = false
    var framePosition: AVAudioFramePosition {
        get { readPosition }
        set { readPosition = max(0, min(newValue, length)); readNeedsSeek = true }
    }
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount? = nil) throws {
        if readNeedsSeek { try provider.seek(to: readPosition); readNeedsSeek = false }
        let requested = min(frameCount ?? buffer.frameCapacity, buffer.frameCapacity)
        guard let channels = buffer.floatChannelData else { throw AudioDecodingError.invalidRange }
        guard let pcm = try provider.nextChunk(maxFrames: requested) else { buffer.frameLength = 0; return }
        guard Int(buffer.format.channelCount) == pcm.channelCount else { throw AudioDecodingError.invalidRange }
        for frame in 0..<pcm.frames {
            for channel in 0..<pcm.channelCount { channels[channel][frame] = pcm.data[frame * pcm.channelCount + channel] }
        }
        buffer.frameLength = AVAudioFrameCount(pcm.frames)
        readPosition += Int64(pcm.frames)
    }

    init(info: AudioDecoderInfo, provider: any RendererPCMProvider, sourceFile: AVAudioFile? = nil) throws {
        self.info = info
        self.provider = AudioCursorPCMProvider(source: provider)
        self.sourceFile = sourceFile
        if let sourceFile {
            processingFormat = sourceFile.processingFormat
        } else {
            guard provider.sourceChannelCount > 0, provider.sourceChannelCount <= 64,
                  provider.sourceSampleRate.isFinite, provider.sourceSampleRate > 0,
                  let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(provider.sourceChannelCount)) else {
                throw AudioDecodingError.invalidRange
            }
            processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: provider.sourceSampleRate, interleaved: false, channelLayout: layout)
        }
    }
    func selecting(_ selection: AudioMediaSelection) throws -> AudioDecoderResource {
        var rangeSelection = selection
        if selection.kind == .sacd {
            rangeSelection = AudioMediaSelection(kind: .sacd, groupID: selection.groupID,
                trackNumber: selection.trackNumber, start: selection.start - (info.programStart ?? 0),
                length: selection.length, timeScale: selection.timeScale, area: selection.area)
        }
        let range = try rangeSelection.decodedRange(sampleRate: sampleRate, totalFrames: length)
        let selected = try AudioDecoderResource(info: info,
            provider: AudioRegionPCMProvider(source: provider, start: range.lowerBound, length: range.upperBound - range.lowerBound),
            sourceFile: sourceFile)
        selected.backingResource = self
        return selected
    }

    func makeProvider(startingFrame: Int64 = 0, frameCount: AVAudioFrameCount? = nil) -> any RendererPCMProvider {
        AudioRegionPCMProvider(source: provider, start: startingFrame,
            length: frameCount.map(Int64.init) ?? max(0, length - startingFrame))
    }
}

nonisolated enum AudioDecoderFactory {
    static let extendedExtensions = AudioFormatSupport.codecLibraryExtensions

    static func open(_ url: URL, selection: AudioMediaSelection? = nil) throws -> AudioDecoderResource {
        let resource = try openPhysical(url, selection: selection)
        return try selection.map { try resource.selecting($0) } ?? resource
    }

    static func openPhysical(_ url: URL, selection: AudioMediaSelection? = nil) throws -> AudioDecoderResource {
        let ext = url.pathExtension.lowercased()
        let resource: AudioDecoderResource
        if extendedExtensions.contains(ext) || ext == "iso" {
            let provider = try NativeAudioPCMProvider(url: url, area: selection?.area ?? -1,
                track: ext == "iso" ? 0 : 1)
            resource = try AudioDecoderResource(info: provider.info, provider: provider)
        } else {
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: url) }
            catch {
                guard ["wav", "wave", "aif", "aiff", "aifc"].contains(ext) else { throw error }
                let provider = try NativeAudioPCMProvider(url: url, area: -1, track: 1)
                let decoded = try AudioDecoderResource(info: provider.info, provider: provider)
                return decoded
            }
            let format = file.processingFormat
            guard file.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
                  format.channelCount > 0 else { throw AudioDecodingError.invalidRange }
            let provider = AVFilePCMProvider(file: file)
            let description = file.fileFormat.streamDescription.pointee
            let codec = codecName(for: description.mFormatID) ?? ext.uppercased()
            var bits = Int(description.mBitsPerChannel)
            if codec == "ALAC" { bits = [1: 16, 2: 20, 3: 24, 4: 32][description.mFormatFlags] ?? bits }
            if codec == "FLAC", let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if let bytes = try? handle.read(upToCount: 26), bytes.count == 26, bytes.starts(with: Data("fLaC".utf8)) {
                    bits = Int((bytes[20] & 1) << 4 | bytes[21] >> 4) + 1
                }
            }
            var info = AudioDecoderInfo(sampleRate: format.sampleRate, sourceSampleRate: format.sampleRate,
                channels: Int(format.channelCount), bitDepth: bits, frames: file.length, codec: codec)
            info.lossless = ["PCM", "FLAC", "ALAC"].contains(codec)
            resource = try AudioDecoderResource(info: info, provider: provider, sourceFile: file)
        }
        return resource
    }

    static func codecName(for formatID: AudioFormatID) -> String? {
        let bytes = [
            UInt8((formatID >> 24) & 0xff),
            UInt8((formatID >> 16) & 0xff),
            UInt8((formatID >> 8) & 0xff),
            UInt8(formatID & 0xff)
        ]
        guard let rawTag = String(bytes: bytes, encoding: .ascii) else { return nil }
        switch rawTag.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "aac": return "AAC"
        case ".mp3": return "MP3"
        case "alac": return "ALAC"
        case "lpcm": return "PCM"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorb": return "Vorbis"
        case "ima4": return "IMA4"
        case "ulaw": return "μ-law"
        case "alaw": return "A-law"
        default: return nil
        }
    }


    static func probe(_ url: URL, selection: AudioMediaSelection? = nil) throws -> AudioDecoderInfo {
        let resource = try open(url, selection: selection)
        guard let block = try resource.provider.nextChunk(maxFrames: 256), block.frames > 0 else {
            throw AudioDecodingError.invalidRange
        }
        return resource.info
    }
}

nonisolated final class NativeAudioPCMProvider: RendererPCMProvider, @unchecked Sendable {
    private let runtime: AudioCodecRuntime
    private let handle: UnsafeMutableRawPointer
    let info: AudioDecoderInfo
    var sourceChannelCount: Int { info.channels }
    var sourceSampleRate: Double { info.sampleRate }
    var totalFrames: AVAudioFramePosition { info.frames }
    var sourceDSPFormat: DSPAudioFormat {
        let labels: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
            kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround,
            kAudioChannelLabel_RightSurround, kAudioChannelLabel_LeftCenter, kAudioChannelLabel_RightCenter,
            kAudioChannelLabel_CenterSurround, kAudioChannelLabel_LeftSurroundDirect,
            kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_TopCenterSurround,
            kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightCenter,
            kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_TopBackLeft,
            kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_TopBackRight]
        let mask = info.channelMask ?? 0
        let ordered = labels.indices.filter { mask & (UInt64(1) << $0) != 0 }.map { UInt32(labels[$0]) }
        let known = ordered.count == info.channels && mask >> labels.count == 0
        return DSPAudioFormat(sampleRate: info.sampleRate, channelCount: info.channels,
            rawLayoutData: nil, channelLabels: known ? ordered : nil, layoutIsKnown: known)
    }

    init(url: URL, area: Int, track: Int) throws {
        let runtime = try AudioCodecRuntime.shared.get()
        guard let handle = url.path.withCString({ runtime.open($0, Int32(area), Int32(track)) }) else {
            throw runtime.error()
        }
        do {
            let data = Data(String(cString: runtime.info(handle)).utf8)
            info = try JSONDecoder().decode(AudioDecoderInfo.self, from: data)
            self.runtime = runtime
            self.handle = handle
        } catch { runtime.close(handle); throw error }
    }
    deinit { runtime.close(handle) }
    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        guard maxFrames > 0, maxFrames <= Int32.max else { throw AudioDecodingError.invalidRange }
        var samples = [Float](repeating: 0, count: Int(maxFrames) * sourceChannelCount)
        let count = samples.withUnsafeMutableBufferPointer { runtime.read(handle, $0.baseAddress!, Int32(maxFrames)) }
        guard count >= 0 else { throw runtime.error() }
        guard count > 0 else { return nil }
        samples.removeLast(samples.count - Int(count) * sourceChannelCount)
        return CanonicalPCM(frames: Int(count), channelCount: sourceChannelCount,
            sampleRate: sourceSampleRate, data: samples)
    }
    func seek(to position: AVAudioFramePosition) throws {
        guard runtime.seek(handle, position) == 0 else { throw runtime.error() }
    }
}

/// Composes source ranges and presents every logical track with a zero origin.
nonisolated final class AudioRegionPCMProvider: RendererPCMProvider, @unchecked Sendable {
    let source: any RendererPCMProvider
    let start: Int64
    let totalFrames: Int64
    private var position: Int64 = 0
    private var needsSeek = true
    var sourceChannelCount: Int { source.sourceChannelCount }
    var sourceSampleRate: Double { source.sourceSampleRate }
    var sourceDSPFormat: DSPAudioFormat { source.sourceDSPFormat }
    init(source: any RendererPCMProvider, start: Int64, length: Int64) {
        self.source = source
        self.start = max(0, min(start, source.totalFrames))
        totalFrames = max(0, min(length, source.totalFrames - self.start))
    }
    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        guard position < totalFrames, maxFrames > 0 else { return nil }
        if needsSeek { try source.seek(to: start + position); needsSeek = false }
        let requested = AVAudioFrameCount(min(Int64(maxFrames), totalFrames - position))
        guard let pcm = try source.nextChunk(maxFrames: requested) else { throw AudioDecodingError.invalidRange }
        position += Int64(pcm.frames)
        return pcm
    }
    func seek(to position: AVAudioFramePosition) throws {
        guard position >= 0, position <= totalFrames else { throw AudioDecodingError.invalidRange }
        self.position = position
        needsSeek = true
    }
    func setDSPReadAheadEnabled(_ enabled: Bool) { source.setDSPReadAheadEnabled(enabled) }
    func peekChunk(at position: AVAudioFramePosition, maxFrames: AVAudioFrameCount,
        restoringTo restorePosition: AVAudioFramePosition) throws -> CanonicalPCM? {
        guard restorePosition >= 0, restorePosition <= totalFrames else { throw AudioDecodingError.invalidRange }
        let offset = max(0, min(position, totalFrames))
        let count = AVAudioFrameCount(min(Int64(maxFrames), totalFrames - offset))
        guard count > 0 else { return nil }
        let pcm = try source.peekChunk(at: start + offset, maxFrames: count, restoringTo: start + restorePosition)
        self.position = restorePosition
        needsSeek = false
        return pcm
    }
}


/// A seek to the existing cursor preserves decoder and resampler history at a
/// contiguous track boundary. All access stays on the renderer's serial queue.
nonisolated final class AudioCursorPCMProvider: RendererPCMProvider, @unchecked Sendable {
    private let source: any RendererPCMProvider
    private var position: Int64 = 0
    var sourceChannelCount: Int { source.sourceChannelCount }
    var sourceSampleRate: Double { source.sourceSampleRate }
    var sourceDSPFormat: DSPAudioFormat { source.sourceDSPFormat }
    var totalFrames: Int64 { source.totalFrames }
    init(source: any RendererPCMProvider) { self.source = source }
    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        let chunk = try source.nextChunk(maxFrames: maxFrames)
        position += Int64(chunk?.frames ?? 0)
        return chunk
    }
    func seek(to position: Int64) throws {
        guard position != self.position else { return }
        try source.seek(to: position)
        self.position = position
    }
    func setDSPReadAheadEnabled(_ enabled: Bool) { source.setDSPReadAheadEnabled(enabled) }
    func peekChunk(at position: AVAudioFramePosition, maxFrames: AVAudioFrameCount,
        restoringTo restorePosition: AVAudioFramePosition) throws -> CanonicalPCM? {
        let pcm = try source.peekChunk(at: position, maxFrames: maxFrames, restoringTo: restorePosition)
        self.position = restorePosition
        return pcm
    }
}
