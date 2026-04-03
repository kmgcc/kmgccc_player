import Foundation
import Cocoa

// MARK: - Apple Music Bridge (NSAppleScript 优化版)
/// 使用 NSAppleScript 复用编译结果，大幅降低 CPU 占用

public final class OptimizedAppleMusicBridge {

    // MARK: - Singleton
    public static let shared = OptimizedAppleMusicBridge()

    // MARK: - 预编译脚本 (复用)
    private var fetchPositionScript: NSAppleScript?
    private var fetchInfoScript: NSAppleScript?
    private var playPauseScript: NSAppleScript?
    private var nextTrackScript: NSAppleScript?
    private var previousTrackScript: NSAppleScript?
    private var checkRunningScript: NSAppleScript?

    // MARK: - 监控配置
    public struct MonitorConfig {
        public let lyricsInterval: TimeInterval    // 歌词同步频率
        public let displayInterval: TimeInterval   // 显示刷新频率

        public static let `default` = MonitorConfig(
            lyricsInterval: 1.0,   // 1.0s 歌词同步
            displayInterval: 2.0   // 2.0s 显示刷新
        )

        public static let lowPower = MonitorConfig(
            lyricsInterval: 1.5,   // 1.5s 歌词同步
            displayInterval: 3.0   // 3.0s 显示刷新
        )
    }

    // MARK: - 监控状态
    private var lyricsTimer: Timer?
    private var displayTimer: Timer?
    private var isMonitoring = false
    private var config: MonitorConfig = .default

    // MARK: - 回调
    public var onLyricsTick: ((NowPlayingInfo) -> Void)?
    public var onDisplayTick: ((NowPlayingInfo) -> Void)?

    // MARK: - 数据模型
    public struct NowPlayingInfo {
        public let title: String?
        public let artist: String?
        public let album: String?
        public let duration: Double
        public let position: Double
        public let state: PlayerState
        public let volume: Int

        public var isPlaying: Bool { state == .playing }
        public var progress: Double {
            guard duration > 0 else { return 0 }
            return position / duration
        }

        public var formattedPosition: String {
            let m = Int(position) / 60
            let s = Int(position) % 60
            return String(format: "%d:%02d", m, s)
        }

        public var formattedDuration: String {
            let m = Int(duration) / 60
            let s = Int(duration) % 60
            return String(format: "%d:%02d", m, s)
        }
    }

    public enum PlayerState: String {
        case playing = "playing"
        case paused = "paused"
        case stopped = "stopped"
        case unknown = "unknown"
    }

    // MARK: - 初始化
    private init() {
        compileScripts()
    }

    // MARK: - 预编译所有脚本
    private func compileScripts() {
        // 1. 检查 Music.app 是否运行 (轻量)
        checkRunningScript = compileScript("""
            tell application "System Events"
                return (name of processes) contains "Music"
            end tell
            """)

        // 2. 仅获取位置和状态 (最频繁调用，最小开销)
        fetchPositionScript = compileScript("""
            tell application "Music"
                try
                    set pos to player position
                    set st to player state as string
                    return pos & "|" & st
                on error
                    return "ERROR"
                end try
            end tell
            """)

        // 3. 获取完整信息 (较少调用)
        fetchInfoScript = compileScript("""
            tell application "Music"
                try
                    set currentTrack to current track
                    set trackName to name of currentTrack
                    set trackArtist to artist of currentTrack
                    set trackAlbum to album of currentTrack
                    set trackDuration to duration of currentTrack
                    set trackPosition to player position
                    set trackState to player state as string
                    set trackVolume to sound volume
                    return trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition & "|" & trackState & "|" & trackVolume
                on error errMsg
                    return "ERROR:" & errMsg
                end try
            end tell
            """)

        // 4. 控制命令 (单次调用)
        playPauseScript = compileScript("tell application \"Music\" to playpause")
        nextTrackScript = compileScript("tell application \"Music\" to next track")
        previousTrackScript = compileScript("tell application \"Music\" to previous track")
    }

    private func compileScript(_ source: String) -> NSAppleScript? {
        guard let script = NSAppleScript(source: source) else { return nil }

        var errorInfo: NSDictionary?
        let success = script.compileAndReturnError(&errorInfo)

        if !success {
            print("[AppleMusicBridge] Failed to compile script: \(errorInfo ?? [:])")
            return nil
        }

        return script
    }

    // MARK: - 执行脚本 (复用)
    private func execute(_ script: NSAppleScript?) -> String {
        guard let script = script else { return "ERROR:Script not compiled" }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            return "ERROR:\(error)"
        }

        return result.stringValue ?? ""
    }

    // MARK: - Public API

    /// 检查 Music.app 是否运行
    public func isMusicAppRunning() -> Bool {
        let result = execute(checkRunningScript)
        return result.lowercased() == "true"
    }

    /// 获取精简信息 (仅位置和状态) - 用于歌词同步
    public func fetchPositionInfo() -> NowPlayingInfo {
        guard isMusicAppRunning() else {
            return NowPlayingInfo(state: .stopped)
        }

        let result = execute(fetchPositionScript)
        return parsePositionResult(result)
    }

    /// 获取完整信息 - 用于显示刷新
    public func fetchFullInfo() -> NowPlayingInfo {
        guard isMusicAppRunning() else {
            return NowPlayingInfo(state: .stopped)
        }

        let result = execute(fetchInfoScript)
        return parseFullResult(result)
    }

    /// 播放/暂停
    @discardableResult
    public func playPause() -> Bool {
        let result = execute(playPauseScript)
        return !result.hasPrefix("ERROR")
    }

    /// 下一首
    @discardableResult
    public func nextTrack() -> Bool {
        let result = execute(nextTrackScript)
        return !result.hasPrefix("ERROR")
    }

    /// 上一首
    @discardableResult
    public func previousTrack() -> Bool {
        let result = execute(previousTrackScript)
        return !result.hasPrefix("ERROR")
    }

    // MARK: - 双频率监控

    /// 开始双频率监控
    public func startMonitoring(config: MonitorConfig = .default) {
        guard !isMonitoring else { return }
        isMonitoring = true
        self.config = config

        // 1. 歌词同步定时器 (高频)
        lyricsTimer = Timer.scheduledTimer(withTimeInterval: config.lyricsInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let info = self.fetchPositionInfo()
            self.onLyricsTick?(info)
        }

        // 2. 显示刷新定时器 (低频)
        displayTimer = Timer.scheduledTimer(withTimeInterval: config.displayInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let info = self.fetchFullInfo()
            self.onDisplayTick?(info)
        }

        // 立即触发一次
        onLyricsTick?(fetchPositionInfo())
        onDisplayTick?(fetchFullInfo())
    }

    /// 停止监控
    public func stopMonitoring() {
        isMonitoring = false
        lyricsTimer?.invalidate()
        displayTimer?.invalidate()
        lyricsTimer = nil
        displayTimer = nil
    }

    // MARK: - 解析结果

    private func parsePositionResult(_ result: String) -> NowPlayingInfo {
        if result.hasPrefix("ERROR") {
            return NowPlayingInfo(state: .unknown)
        }

        let parts = result.components(separatedBy: "|")
        guard parts.count >= 2 else {
            return NowPlayingInfo(state: .unknown)
        }

        return NowPlayingInfo(
            title: nil,
            artist: nil,
            album: nil,
            duration: 0,
            position: Double(parts[0]) ?? 0,
            state: PlayerState(rawValue: parts[1]) ?? .unknown,
            volume: 100
        )
    }

    private func parseFullResult(_ result: String) -> NowPlayingInfo {
        if result.hasPrefix("ERROR") {
            return NowPlayingInfo(state: .unknown)
        }

        let parts = result.components(separatedBy: "|")
        guard parts.count >= 7 else {
            return NowPlayingInfo(state: .unknown)
        }

        return NowPlayingInfo(
            title: parts[0].isEmpty ? nil : parts[0],
            artist: parts[1].isEmpty ? nil : parts[1],
            album: parts[2].isEmpty ? nil : parts[2],
            duration: Double(parts[3]) ?? 0,
            position: Double(parts[4]) ?? 0,
            state: PlayerState(rawValue: parts[5]) ?? .unknown,
            volume: Int(parts[6]) ?? 100
        )
    }
}

// MARK: - Convenience Init
extension OptimizedAppleMusicBridge.NowPlayingInfo {
    init(state: OptimizedAppleMusicBridge.PlayerState) {
        self.title = nil
        self.artist = nil
        self.album = nil
        self.duration = 0
        self.position = 0
        self.state = state
        self.volume = 100
    }
}
