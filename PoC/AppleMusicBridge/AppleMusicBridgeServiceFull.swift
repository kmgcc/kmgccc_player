import Foundation

// MARK: - Types

/// Music.app 播放状态
public enum AppleMusicPlayerState: String, Sendable {
    case playing = "playing"
    case paused = "paused"
    case stopped = "stopped"
    case fastForwarding = "fast forwarding"
    case rewinding = "rewinding"
    case unknown = "unknown"
}

/// 云端状态
public enum AppleMusicCloudStatus: String, Sendable {
    case subscription = "subscription"  // Apple Music 订阅
    case matched = "matched"            // iCloud 音乐库匹配
    case purchased = "purchased"        // iTunes Store 购买
    case uploaded = "uploaded"          // 用户上传
    case unknown = "unknown"
}

/// 重复模式
public enum AppleMusicRepeatMode: String, Sendable {
    case off = "off"
    case one = "one"
    case all = "all"
    case unknown = "unknown"
}

/// 完整的当前播放信息
public struct AppleMusicNowPlaying: Sendable {
    // MARK: - 核心信息 (Essential)
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double
    public let position: Double
    public let state: AppleMusicPlayerState

    // MARK: - 创作者与分类 (Creator & Genre)
    public let albumArtist: String?
    public let composer: String?
    public let genre: String?
    public let grouping: String?

    // MARK: - 标识 (Identifiers)
    public let trackID: Int?
    public let persistentID: String?

    // MARK: - 音轨编号 (Track Numbers)
    public let trackNumber: Int
    public let trackCount: Int
    public let discNumber: Int
    public let discCount: Int

    // MARK: - 年份与时间 (Dates)
    public let year: Int
    public let releaseDate: String?
    public let dateAdded: String?

    // MARK: - 播放统计 (Stats)
    public let rating: Int  // 0-100
    public let isLoved: Bool
    public let isDisliked: Bool
    public let playedCount: Int
    public let skippedCount: Int

    // MARK: - 音频技术参数 (Audio Technical)
    public let sampleRate: Int  // Hz
    public let bitRate: Int     // kbps
    public let bpm: Int
    public let start: Double
    public let finish: Double

    // MARK: - 来源与格式 (Source & Format)
    public let kind: String?
    public let mediaKind: String?
    public let fileType: String?
    public let isCompilation: Bool
    public let isPurchased: Bool
    public let isAppleMusic: Bool
    public let cloudStatus: AppleMusicCloudStatus
    public let isPodcast: Bool
    public let isVideo: Bool

    // MARK: - 内容
    public let lyrics: String?
    public let artworkCount: Int

    // MARK: - 播放列表 (Playlist)
    public let playlistName: String?
    public let playlistDuration: Double
    public let playlistTrackCount: Int
    public let playlistIndex: Int

    // MARK: - 播放设置 (Settings)
    public let volume: Int  // 0-100
    public let isShuffleEnabled: Bool
    public let repeatMode: AppleMusicRepeatMode
    public let isAirPlayEnabled: Bool

    // MARK: - 错误
    public let error: String?

    // MARK: - 初始化
    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double = 0,
        position: Double = 0,
        state: AppleMusicPlayerState = .unknown,
        albumArtist: String? = nil,
        composer: String? = nil,
        genre: String? = nil,
        grouping: String? = nil,
        trackID: Int? = nil,
        persistentID: String? = nil,
        trackNumber: Int = 0,
        trackCount: Int = 0,
        discNumber: Int = 0,
        discCount: Int = 0,
        year: Int = 0,
        releaseDate: String? = nil,
        dateAdded: String? = nil,
        rating: Int = 0,
        isLoved: Bool = false,
        isDisliked: Bool = false,
        playedCount: Int = 0,
        skippedCount: Int = 0,
        sampleRate: Int = 0,
        bitRate: Int = 0,
        bpm: Int = 0,
        start: Double = 0,
        finish: Double = 0,
        kind: String? = nil,
        mediaKind: String? = nil,
        fileType: String? = nil,
        isCompilation: Bool = false,
        isPurchased: Bool = false,
        isAppleMusic: Bool = false,
        cloudStatus: AppleMusicCloudStatus = .unknown,
        isPodcast: Bool = false,
        isVideo: Bool = false,
        lyrics: String? = nil,
        artworkCount: Int = 0,
        playlistName: String? = nil,
        playlistDuration: Double = 0,
        playlistTrackCount: Int = 0,
        playlistIndex: Int = 0,
        volume: Int = 100,
        isShuffleEnabled: Bool = false,
        repeatMode: AppleMusicRepeatMode = .off,
        isAirPlayEnabled: Bool = false,
        error: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.state = state
        self.albumArtist = albumArtist
        self.composer = composer
        self.genre = genre
        self.grouping = grouping
        self.trackID = trackID
        self.persistentID = persistentID
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.year = year
        self.releaseDate = releaseDate
        self.dateAdded = dateAdded
        self.rating = rating
        self.isLoved = isLoved
        self.isDisliked = isDisliked
        self.playedCount = playedCount
        self.skippedCount = skippedCount
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.bpm = bpm
        self.start = start
        self.finish = finish
        self.kind = kind
        self.mediaKind = mediaKind
        self.fileType = fileType
        self.isCompilation = isCompilation
        self.isPurchased = isPurchased
        self.isAppleMusic = isAppleMusic
        self.cloudStatus = cloudStatus
        self.isPodcast = isPodcast
        self.isVideo = isVideo
        self.lyrics = lyrics
        self.artworkCount = artworkCount
        self.playlistName = playlistName
        self.playlistDuration = playlistDuration
        self.playlistTrackCount = playlistTrackCount
        self.playlistIndex = playlistIndex
        self.volume = volume
        self.isShuffleEnabled = isShuffleEnabled
        self.repeatMode = repeatMode
        self.isAirPlayEnabled = isAirPlayEnabled
        self.error = error
    }

    // MARK: - 计算属性
    public var isValid: Bool {
        error == nil && title != nil
    }

    public var isPlaying: Bool {
        state == .playing
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return position / duration
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

/// 通过 AppleScript 控制 Music.app 的完整服务
public final class AppleMusicBridgeService {

    // MARK: - Singleton
    public static let shared = AppleMusicBridgeService()

    // MARK: - Properties
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

    /// 获取完整当前播放信息（包含所有可用字段）
    public func fetchNowPlaying() -> AppleMusicNowPlaying {
        guard isMusicAppRunning() else {
            return AppleMusicNowPlaying(state: .stopped, error: "Music.app not running")
        }

        let script = buildFullTrackQueryScript()
        let result = executeAppleScript(script)
        return parseFullResult(result)
    }

    /// 获取精简版当前播放信息（仅核心字段）
    public func fetchNowPlayingMinimal() -> AppleMusicNowPlaying {
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
        return parseMinimalResult(result)
    }

    // MARK: - Control Commands

    @discardableResult
    public func playPause() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        return executeControlScript("playpause")
    }

    @discardableResult
    public func play() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        return executeControlScript("play")
    }

    @discardableResult
    public func pause() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        return executeControlScript("pause")
    }

    @discardableResult
    public func stop() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        return executeControlScript("stop")
    }

    @discardableResult
    public func nextTrack() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        return executeControlScript("next track")
    }

    @discardableResult
    public func previousTrack() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        return executeControlScript("previous track")
    }

    @discardableResult
    public func setPosition(_ position: Double) -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        return executeControlScript("set player position to \(position)")
    }

    @discardableResult
    public func setVolume(_ volume: Int) -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }
        let clampedVolume = max(0, min(100, volume))
        return executeControlScript("set sound volume to \(clampedVolume)")
    }

    @discardableResult
    public func toggleShuffle() -> AppleMusicControlResult {
        guard isMusicAppRunning() else {
            return AppleMusicControlResult(success: false, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                set shuffle enabled to not shuffle enabled
                return "OK"
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
        let result = executeAppleScript(script)
        return AppleMusicControlResult(success: result == "OK", error: nil)
    }

    // MARK: - Monitoring

    public func startMonitoring(interval: TimeInterval = 1.0, detailed: Bool = false, callback: @escaping (AppleMusicNowPlaying) -> Void) {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let info = detailed ? self.fetchNowPlaying() : self.fetchNowPlayingMinimal()
            callback(info)
        }
    }

    public func stopMonitoring() {
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    // MARK: - Private Helpers

    private func buildFullTrackQueryScript() -> String {
        return """
        tell application "Music"
            try
                -- Current track
                set currentTrack to current track
                set trackName to name of currentTrack
                set trackArtist to artist of currentTrack
                set trackAlbum to album of currentTrack

                -- Extended properties
                try
                    set trackAlbumArtist to album artist of currentTrack
                on error
                    set trackAlbumArtist to ""
                end try

                try
                    set trackComposer to composer of currentTrack
                on error
                    set trackComposer to ""
                end try

                try
                    set trackGenre to genre of currentTrack
                on error
                    set trackGenre to ""
                end try

                try
                    set trackGrouping to grouping of currentTrack
                on error
                    set trackGrouping to ""
                end try

                -- Identifiers
                try
                    set trackID to id of currentTrack
                on error
                    set trackID to 0
                end try

                try
                    set trackPersistentID to persistent ID of currentTrack
                on error
                    set trackPersistentID to ""
                end try

                -- Timing
                try
                    set trackDuration to duration of currentTrack
                on error
                    set trackDuration to 0
                end try

                try
                    set trackStart to start of currentTrack
                on error
                    set trackStart to 0
                end try

                try
                    set trackFinish to finish of currentTrack
                on error
                    set trackFinish to 0
                end try

                -- Track numbers
                try
                    set trackTrackNumber to track number of currentTrack
                on error
                    set trackTrackNumber to 0
                end try

                try
                    set trackTrackCount to track count of currentTrack
                on error
                    set trackTrackCount to 0
                end try

                try
                    set trackDiscNumber to disc number of currentTrack
                on error
                    set trackDiscNumber to 0
                end try

                try
                    set trackDiscCount to disc count of currentTrack
                on error
                    set trackDiscCount to 0
                end try

                -- Dates
                try
                    set trackYear to year of currentTrack
                on error
                    set trackYear to 0
                end try

                try
                    set trackReleaseDate to release date of currentTrack
                on error
                    set trackReleaseDate to ""
                end try

                try
                    set trackDateAdded to date added of currentTrack
                on error
                    set trackDateAdded to ""
                end try

                -- Stats
                try
                    set trackRating to rating of currentTrack
                on error
                    set trackRating to 0
                end try

                try
                    set trackLoved to loved of currentTrack
                on error
                    set trackLoved to false
                end try

                try
                    set trackDisliked to disliked of currentTrack
                on error
                    set trackDisliked to false
                end try

                try
                    set trackPlayedCount to played count of currentTrack
                on error
                    set trackPlayedCount to 0
                end try

                try
                    set trackSkippedCount to skipped count of currentTrack
                on error
                    set trackSkippedCount to 0
                end try

                -- Audio
                try
                    set trackSampleRate to sample rate of currentTrack
                on error
                    set trackSampleRate to 0
                end try

                try
                    set trackBitRate to bit rate of currentTrack
                on error
                    set trackBitRate to 0
                end try

                try
                    set trackBPM to bpm of currentTrack
                on error
                    set trackBPM to 0
                end try

                -- Source
                try
                    set trackKind to kind of currentTrack
                on error
                    set trackKind to ""
                end try

                try
                    set trackCloudStatus to cloud status of currentTrack as string
                on error
                    set trackCloudStatus to ""
                end try

                try
                    set trackCompilation to compilation of currentTrack
                on error
                    set trackCompilation to false
                end try

                -- Player state
                set playerPos to player position
                set playerState to player state as string
                set playerVolume to sound volume
                set playerShuffle to shuffle enabled
                set playerRepeat to song repeat as string

                -- Playlist
                try
                    set currentPlaylist to current playlist
                    set playlistName to name of currentPlaylist
                    set playlistDuration to duration of currentPlaylist
                    set playlistCount to count of tracks of currentPlaylist
                    set currentIndex to index of currentTrack
                on error
                    set playlistName to ""
                    set playlistDuration to 0
                    set playlistCount to 0
                    set currentIndex to 0
                end try

                -- Build output (tab-separated for reliability)
                set output to "OK" & "\t" & trackName & "\t" & trackArtist & "\t" & trackAlbum & "\t" & trackAlbumArtist & "\t" & trackComposer & "\t" & trackGenre & "\t" & trackGrouping & "\t" & trackID & "\t" & trackPersistentID & "\t" & trackDuration & "\t" & trackStart & "\t" & trackFinish & "\t" & trackTrackNumber & "\t" & trackTrackCount & "\t" & trackDiscNumber & "\t" & trackDiscCount & "\t" & trackYear & "\t" & trackReleaseDate & "\t" & trackDateAdded & "\t" & trackRating & "\t" & trackLoved & "\t" & trackDisliked & "\t" & trackPlayedCount & "\t" & trackSkippedCount & "\t" & trackSampleRate & "\t" & trackBitRate & "\t" & trackBPM & "\t" & trackKind & "\t" & trackCloudStatus & "\t" & trackCompilation & "\t" & playerPos & "\t" & playerState & "\t" & playerVolume & "\t" & playerShuffle & "\t" & playerRepeat & "\t" & playlistName & "\t" & playlistDuration & "\t" & playlistCount & "\t" & currentIndex

                return output

            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """
    }

    private func executeControlScript(_ command: String) -> AppleMusicControlResult {
        let script = """
        tell application "Music"
            try
                \(command)
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

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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

    private func parseMinimalResult(_ result: String) -> AppleMusicNowPlaying {
        if result.hasPrefix("ERROR:") {
            return AppleMusicNowPlaying(state: .unknown, error: String(result.dropFirst(6)))
        }

        let parts = result.components(separatedBy: "|")
        guard parts.count >= 7, parts[0] == "OK" else {
            return AppleMusicNowPlaying(state: .unknown, error: "Parse error")
        }

        return AppleMusicNowPlaying(
            title: parts[1].isEmpty ? nil : parts[1],
            artist: parts[2].isEmpty ? nil : parts[2],
            album: parts[3].isEmpty ? nil : parts[3],
            duration: Double(parts[4]) ?? 0,
            position: Double(parts[5]) ?? 0,
            state: AppleMusicPlayerState(rawValue: parts[6]) ?? .unknown
        )
    }

    private func parseFullResult(_ result: String) -> AppleMusicNowPlaying {
        if result.hasPrefix("ERROR:") {
            return AppleMusicNowPlaying(state: .unknown, error: String(result.dropFirst(6)))
        }

        let parts = result.components(separatedBy: "\t")
        guard parts.count >= 41, parts[0] == "OK" else {
            return AppleMusicNowPlaying(state: .unknown, error: "Parse error (got \(parts.count) fields)")
        }

        return AppleMusicNowPlaying(
            title: parts[1].isEmpty ? nil : parts[1],
            artist: parts[2].isEmpty ? nil : parts[2],
            album: parts[3].isEmpty ? nil : parts[3],
            duration: Double(parts[11]) ?? 0,
            position: Double(parts[32]) ?? 0,
            state: AppleMusicPlayerState(rawValue: parts[33]) ?? .unknown,
            albumArtist: parts[4].isEmpty ? nil : parts[4],
            composer: parts[5].isEmpty ? nil : parts[5],
            genre: parts[6].isEmpty ? nil : parts[6],
            grouping: parts[7].isEmpty ? nil : parts[7],
            trackID: Int(parts[8]),
            persistentID: parts[9].isEmpty ? nil : parts[9],
            trackNumber: Int(parts[13]) ?? 0,
            trackCount: Int(parts[14]) ?? 0,
            discNumber: Int(parts[15]) ?? 0,
            discCount: Int(parts[16]) ?? 0,
            year: Int(parts[17]) ?? 0,
            releaseDate: parts[18].isEmpty ? nil : parts[18],
            dateAdded: parts[19].isEmpty ? nil : parts[19],
            rating: Int(parts[20]) ?? 0,
            isLoved: parts[21].lowercased() == "true",
            isDisliked: parts[22].lowercased() == "true",
            playedCount: Int(parts[23]) ?? 0,
            skippedCount: Int(parts[24]) ?? 0,
            sampleRate: Int(parts[25]) ?? 0,
            bitRate: Int(parts[26]) ?? 0,
            bpm: Int(parts[27]) ?? 0,
            start: Double(parts[12]) ?? 0,
            finish: Double(parts[12]) ?? 0,
            kind: parts[28].isEmpty ? nil : parts[28],
            isCompilation: parts[30].lowercased() == "true",
            cloudStatus: AppleMusicCloudStatus(rawValue: parts[29]) ?? .unknown,
            volume: Int(parts[34]) ?? 100,
            isShuffleEnabled: parts[35].lowercased() == "true",
            repeatMode: AppleMusicRepeatMode(rawValue: parts[36]) ?? .off,
            playlistName: parts[37].isEmpty ? nil : parts[37],
            playlistDuration: Double(parts[38]) ?? 0,
            playlistTrackCount: Int(parts[39]) ?? 0,
            playlistIndex: Int(parts[40]) ?? 0
        )
    }
}

// MARK: - Extensions

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

    /// 进度百分比 (0-100)
    public var progressPercentage: Double {
        guard duration > 0 else { return 0 }
        return (position / duration) * 100
    }

    /// 简洁的日志输出
    public var debugDescription: String {
        if let error = error {
            return "Error: \(error)"
        }
        return "\(title ?? "(no title)") - \(artist ?? "(no artist)") [\(formattedPosition)/\(formattedDuration)] (\(state.rawValue))"
    }
}
