import Foundation
import AVFoundation
import Accelerate

public enum VirtualBassMode: String, CaseIterable, Identifiable, Sendable {
    case bypass = "直通 (Bypass)"
    case originalClassic = "原版经典 (破音复现)"
    case fixedClassic = "修复版经典 (推荐)"
    case originalHybrid = "原版混合 (破音复现)"
    case fixedHybrid = "修复版混合 (推荐)"

    public var id: String { rawValue }
}

public struct VirtualBassParams: Equatable, Sendable {
    public var cutoffHz: Double = 100.0
    public var intensity: Double = 1.0
    public var transient: Double = 1.0
    public var character: Double = 0.7
    public var wetSolo: Bool = false
    public var bassGainDB: Double = 0.0
    public var outputTrimDB: Double = 0.0
    public var tightenDryBass: Bool = false

    public init() {}
}

@MainActor
public final class AudioPlayerEngine: ObservableObject {
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentFileName: String = "未加载音频"
    @Published public private(set) var currentFormatDescription: String = "44.1 kHz, 2 声道"
    @Published public private(set) var duration: Double = 0.0
    @Published public var currentTime: Double = 0.0
    @Published public var volume: Float = 0.9

    // 模式与参数
    @Published public var mode: VirtualBassMode = .fixedClassic {
        didSet { updateDSP() }
    }
    @Published public var params = VirtualBassParams() {
        didSet { updateDSP() }
    }

    // 实时电平表 (0.0 ~ 1.0)
    @Published public private(set) var leftMeter: Float = 0.0
    @Published public private(set) var rightMeter: Float = 0.0
    @Published public private(set) var isClipping: Bool = false

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var audioBuffer: AVAudioPCMBuffer?
    private var playheadFrame: Int64 = 0
    private var totalFrames: Int64 = 0
    private var sampleRate: Double = 44100.0
    private var channelCount: Int = 2

    // DSP 内核锁与状态
    private let dspLock = os_unfair_lock_t.allocate(capacity: 1)
    private var activeMode: VirtualBassMode = .fixedClassic
    private var activeOriginalClassic: OriginalClassicBass?
    private var activeFixedClassic: FixedClassicBass?
    private var activeOriginalHybrid: OriginalHybridBass?
    private var activeFixedHybrid: FixedHybridBass?

    private var displayLinkTimer: Timer?

    public init() {
        dspLock.initialize(to: os_unfair_lock())
        setupEngine()
        startTimer()
    }

    deinit {
        displayLinkTimer?.invalidate()
        dspLock.deallocate()
    }

    private func setupEngine() {
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44100.0
        channelCount = max(2, Int(outputFormat.channelCount))

        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))!

        let node = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
        }
        self.sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
        engine.mainMixerNode.outputVolume = volume

        do {
            try engine.start()
        } catch {
            print("AVAudioEngine 启动失败: \(error)")
        }

        updateDSP()
    }

    public func loadFile(url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameLength = AVAudioFrameCount(file.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
                return
            }
            try file.read(into: buffer)

            // 如果文件格式和输出格式不同，做格式转换
            let targetFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))!
            let finalBuffer: AVAudioPCMBuffer
            if format.sampleRate != sampleRate || format.channelCount != channelCount {
                guard let converter = AVAudioConverter(from: format, to: targetFormat) else { return }
                let ratio = sampleRate / format.sampleRate
                let targetCapacity = AVAudioFrameCount(Double(frameLength) * ratio + 1024)
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else { return }

                var error: NSError?
                var allRead = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if allRead {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    allRead = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                finalBuffer = converted
            } else {
                finalBuffer = buffer
            }

            self.audioBuffer = finalBuffer
            self.totalFrames = Int64(finalBuffer.frameLength)
            self.playheadFrame = 0
            self.duration = Double(totalFrames) / sampleRate
            self.currentFileName = url.lastPathComponent
            self.currentFormatDescription = String(format: "%.1f kHz, %d 声道", sampleRate / 1000.0, channelCount)

            updateDSP()
            play()
        } catch {
            print("加载音频文件失败: \(error)")
        }
    }

    public func play() {
        guard audioBuffer != nil else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        isPlaying = true
    }

    public func pause() {
        isPlaying = false
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(to progress: Double) {
        let clamped = max(0.0, min(1.0, progress))
        playheadFrame = Int64(clamped * Double(totalFrames))
        currentTime = Double(playheadFrame) / sampleRate
    }

    public func setVolume(_ val: Float) {
        volume = max(0, min(1, val))
        engine.mainMixerNode.outputVolume = volume
    }

    private func updateDSP() {
        os_unfair_lock_lock(dspLock)
        activeMode = mode
        let p = params
        let rate = sampleRate
        let ch = channelCount

        switch mode {
        case .bypass:
            break
        case .originalClassic:
            activeOriginalClassic = OriginalClassicBass(
                sampleRate: rate, channels: ch,
                cutoffHz: p.cutoffHz, floorHz: 35,
                intensity: p.intensity, bassGainDB: p.bassGainDB,
                tightenDryBass: p.tightenDryBass, outputTrimDB: p.outputTrimDB
            )
        case .fixedClassic:
            activeFixedClassic = FixedClassicBass(
                sampleRate: rate, channels: ch,
                cutoffHz: p.cutoffHz, floorHz: 35,
                intensity: p.intensity, bassGainDB: p.bassGainDB,
                tightenDryBass: p.tightenDryBass,
                character: p.character, wetSolo: p.wetSolo,
                outputTrimDB: p.outputTrimDB
            )
        case .originalHybrid:
            activeOriginalHybrid = OriginalHybridBass(
                sampleRate: rate, channels: ch,
                cutoffHz: p.cutoffHz, intensity: p.intensity,
                bassGainDB: p.bassGainDB, tightenDryBass: p.tightenDryBass,
                outputTrimDB: p.outputTrimDB
            )
        case .fixedHybrid:
            activeFixedHybrid = FixedHybridBass(
                sampleRate: rate, channels: ch,
                cutoffHz: p.cutoffHz, floorHz: 35,
                intensity: p.intensity, transient: p.transient,
                bassGainDB: p.bassGainDB, tightenDryBass: p.tightenDryBass,
                character: p.character, wetSolo: p.wetSolo,
                outputTrimDB: p.outputTrimDB
            )
        }
        os_unfair_lock_unlock(dspLock)
    }

    private func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let chCount = abl.count

        guard isPlaying, let buffer = audioBuffer, totalFrames > 0 else {
            for buf in abl {
                memset(buf.mData, 0, Int(buf.mDataByteSize))
            }
            return noErr
        }

        guard let channelData = buffer.floatChannelData else {
            return noErr
        }

        var peakL: Float = 0.0
        var peakR: Float = 0.0

        os_unfair_lock_lock(dspLock)
        let currentMode = activeMode

        for frame in 0..<frameCount {
            let currentIdx = playheadFrame
            if currentIdx >= totalFrames {
                // 播放完毕，循环播放
                playheadFrame = 0
            }

            for ch in 0..<chCount {
                guard let destPtr = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let sourceCh = ch < buffer.format.channelCount ? ch : 0
                let rawSample = Double(channelData[sourceCh][Int(playheadFrame)])

                var processedSample = rawSample
                switch currentMode {
                case .bypass:
                    processedSample = rawSample
                case .originalClassic:
                    if activeOriginalClassic != nil {
                        processedSample = activeOriginalClassic!.process(channel: ch, sample: rawSample)
                    }
                case .fixedClassic:
                    if activeFixedClassic != nil {
                        processedSample = activeFixedClassic!.process(channel: ch, sample: rawSample)
                    }
                case .originalHybrid:
                    if activeOriginalHybrid != nil {
                        processedSample = activeOriginalHybrid!.process(channel: ch, sample: rawSample)
                    }
                case .fixedHybrid:
                    if activeFixedHybrid != nil {
                        processedSample = activeFixedHybrid!.process(channel: ch, sample: rawSample)
                    }
                }

                let outFloat = Float(processedSample)
                destPtr[frame] = outFloat

                let absVal = abs(outFloat)
                if ch == 0 { peakL = max(peakL, absVal) }
                if ch == 1 || chCount == 1 { peakR = max(peakR, absVal) }
            }

            playheadFrame += 1
        }
        os_unfair_lock_unlock(dspLock)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.leftMeter = min(1.0, peakL)
            self.rightMeter = min(1.0, peakR)
            self.isClipping = peakL >= 0.999 || peakR >= 0.999
        }

        return noErr
    }

    private func startTimer() {
        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isPlaying, self.totalFrames > 0 else { return }
                self.currentTime = Double(self.playheadFrame) / self.sampleRate
            }
        }
    }
}
