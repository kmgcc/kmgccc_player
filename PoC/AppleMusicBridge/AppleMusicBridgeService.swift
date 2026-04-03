import Foundation

// MARK: - Types

/// Music.app 播放状态
public enum AppleMusicPlayerState: String, Sendable {
    case playing = "playing"
    case paused = "paused"
    case stopped = "stopped"
    case unknown = "unknown"
}

/// 当前播放信息
public struct AppleMusicNowPlaying: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double
    public let position: Double
    public let state: AppleMusicPlayerState
    public let error: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double = 0,
        position: Double = 0,
        state: AppleMusicPlayerState = .unknown,
        error: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.state = state
        self.error = error
    }

    public var isValid: Bool {
        error == nil && title != nil
    }
}

/// 控制结果
public struct AppleMusicControlResult: Sendable {
    public let success: Bool
    public let error: String?

    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}

// MARK: - Apple Music Bridge Service

/// 通过 AppleScript 控制 Music.app 的服务
public final class AppleMusicBridgeService {

    // MARK: - Singleton
    public static let shared = AppleMusicBridgeService()

    // MARK: - Properties
    private let queue = DispatchQueue(label: "AppleMusicBridge", qos: .userInitiated)
    private var isMonitoring = false
    private var monitorTimer: Timer?

    // 权限缓存
    private var hasPermission: Bool = false
    private var permissionChecked: Bool = false

    // MARK: - Initialization
    private init() {}

    // MARK: - Public API

    /// 检查 Music.app 是否正在运行
    public func isMusicAppRunning() -> Bool {
        let script = """
        tell application "System Events"
            return (name of processes) contains "Music"
        end tell
        """
        let result = executeAppleScript(script)
        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    /// 检查自动化权限
    public func checkAutomationPermission() -> Bool {
        if permissionChecked { return hasPermission }

        let script = """
        tell application "Music"
            return "PERMISSION_OK"
        end tell
        """
        let result = executeAppleScript(script)
        hasPermission = result.contains("PERMISSION_OK")
        permissionChecked = true
        return hasPermission
    }

    /// 获取当前播放信息
    public func fetchNowPlaying() -> AppleMusicNowPlaying {
        // 先检查 Music.app 是否运行
        guard isMusicAppRunning() else {
            return AppleMusicNowPlaying(state: .stopped, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                set currentTrack to current track
                set trackName to name of currentTrack
                set trackArtist to artist of currentTrack
                set trackAlbum to album of currentTrack
                set trackDuration to duration of currentTrack
                set trackPosition to player position
                set trackState to player state as string

                return "OK|" & trackName & "|" & trackArtist & "|" & trackAlbum & "|" & trackDuration & "|" & trackPosition & "|" & trackState
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """

        let result = executeAppleScript(script)
        return parseNowPlayingResult(result)
    }

    /// 播放/暂停切换
    @discardableResult
    public func playPause() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                playpause
                return "OK"
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        let result = executeAppleScript(script)
        return AppleMusicControlResult(
            success: result == "OK",
            error: result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil
        )
    }

    /// 下一首
    @discardableResult
    public func nextTrack() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                next track
                return "OK"
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        let result = executeAppleScript(script)
        return AppleMusicControlResult(
            success: result == "OK",
            error: result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil
        )
    }

    /// 上一首
    @discardableResult
    public func previousTrack() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                previous track
                return "OK"
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        let result = executeAppleScript(script)
        return AppleMusicControlResult(
            success: result == "OK",
            error: result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil
        )
    }

    /// 开始播放（如果已暂停）
    @discardableResult
    public func play() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                play
                return "OK"
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        let result = executeAppleScript(script)
        return AppleMusicControlResult(
            success: result == "OK",
            error: result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil
        )
    }

    /// 暂停
    @discardableResult
    public func pause() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                pause
                return "OK"
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        let result = executeAppleScript(script)
        return AppleMusicControlResult(
            success: result == "OK",
            error: result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil
        )
    }

    /// 设置播放位置
    @discardableResult
    public func setPosition(_ position: Double) -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                set player position to \(position)
                return "OK"
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        let result = executeAppleScript(script)
        return AppleMusicControlResult(
            success: result == "OK",
            error: result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil
        )
    }

    // MARK: - Monitoring

    /// 开始定时轮询监控
    public func startMonitoring(interval: TimeInterval = 1.0, callback: @escaping (AppleMusicNowPlaying) -> Void) {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let info = self.fetchNowPlaying()
            callback(info)
        }
    }

    /// 停止监控
    public func stopMonitoring() {
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    // MARK: - Private Helpers

    private func executeAppleScript(_ source: String) -> String {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "ERROR:\(errorOutput)"
            }

            return output
        } catch {
            return "ERROR:\(error.localizedDescription)"
        }
    }

    private func parseNowPlayingResult(_ result: String) -> AppleMusicNowPlaying {
        if result.hasPrefix("ERROR:") {
            let errorMsg = String(result.dropFirst(6))
            return AppleMusicNowPlaying(state: .unknown, error: errorMsg)
        }

        let parts = result.components(separatedBy: "|")
        guard parts.count >= 7, parts[0] == "OK" else {
            return AppleMusicNowPlaying(state: .unknown, error: "Parse error: \(result)")
        }

        let title = parts[1].isEmpty ? nil : parts[1]
        let artist = parts[2].isEmpty ? nil : parts[2]
        let album = parts[3].isEmpty ? nil : parts[3]
        let duration = Double(parts[4]) ?? 0
        let position = Double(parts[5]) ?? 0
        let state = AppleMusicPlayerState(rawValue: parts[6]) ?? .unknown

        return AppleMusicNowPlaying(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            state: state,
            error: nil
        )
    }
}

// MARK: - Convenience Extensions

extension AppleMusicNowPlaying {
    /// 格式化的位置字符串 (mm:ss)
    public var formattedPosition: String {
        let minutes = Int(position) / 60
        let seconds = Int(position) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// 格式化的时长字符串 (mm:ss)
    public var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// 进度百分比
    public var progressPercentage: Double {
        guard duration > 0 else { return 0 }
        return (position / duration) * 100
    }
}
