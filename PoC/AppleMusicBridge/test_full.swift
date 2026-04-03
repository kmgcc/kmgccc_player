import Foundation

// MARK: - Simple Test

print("""
╔════════════════════════════════════════════════════════════════╗
║     AppleMusicBridge - 完整属性测试                            ║
╠════════════════════════════════════════════════════════════════╣
║  测试 AppleScript 能获取的所有详细信息                          ║
╚════════════════════════════════════════════════════════════════╝
""")

// Check if Music.app is running
let checkScript = """
tell application "System Events"
    return (name of processes) contains "Music"
end tell
"""

func executeAppleScript(_ source: String) -> String {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", source]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch {
        return "ERROR: \(error)"
    }
}

let isRunning = executeAppleScript(checkScript).lowercased() == "true"

if !isRunning {
    print("❌ Music.app 未运行")
    print("请先启动 Music.app 并播放一首歌曲")
    exit(1)
}

print("✅ Music.app 正在运行\n")

// Full query script
let fullScript = """
tell application "Music"
    try
        set currentTrack to current track
        set trackName to name of currentTrack
        set trackArtist to artist of currentTrack
        set trackAlbum to album of currentTrack

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
            set trackID to id of currentTrack
        on error
            set trackID to 0
        end try

        try
            set trackPersistentID to persistent ID of currentTrack
        on error
            set trackPersistentID to ""
        end try

        try
            set trackDuration to duration of currentTrack
        on error
            set trackDuration to 0
        end try

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
            set trackYear to year of currentTrack
        on error
            set trackYear to 0
        end try

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
            set trackPlayedCount to played count of currentTrack
        on error
            set trackPlayedCount to 0
        end try

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

        try
            set trackLyrics to lyrics of currentTrack
        on error
            set trackLyrics to ""
        end try

        set playerPos to player position
        set playerState to player state as string
        set playerVolume to sound volume
        set playerShuffle to shuffle enabled
        set playerRepeat to song repeat as string

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

        -- Build output with clear separators
        set output to "===TRACK===" & "\n"
        set output to output & "Name: " & trackName & "\n"
        set output to output & "Artist: " & trackArtist & "\n"
        set output to output & "Album: " & trackAlbum & "\n"
        set output to output & "AlbumArtist: " & trackAlbumArtist & "\n"
        set output to output & "Composer: " & trackComposer & "\n"
        set output to output & "Genre: " & trackGenre & "\n"
        set output to output & "===IDENTIFIERS===" & "\n"
        set output to output & "ID: " & trackID & "\n"
        set output to output & "PersistentID: " & trackPersistentID & "\n"
        set output to output & "===TIMING===" & "\n"
        set output to output & "Duration: " & trackDuration & "\n"
        set output to output & "TrackNumber: " & trackTrackNumber & "\n"
        set output to output & "TrackCount: " & trackTrackCount & "\n"
        set output to output & "DiscNumber: " & trackDiscNumber & "\n"
        set output to output & "Year: " & trackYear & "\n"
        set output to output & "===STATS===" & "\n"
        set output to output & "Rating: " & trackRating & "\n"
        set output to output & "Loved: " & trackLoved & "\n"
        set output to output & "PlayedCount: " & trackPlayedCount & "\n"
        set output to output & "===AUDIO===" & "\n"
        set output to output & "SampleRate: " & trackSampleRate & "\n"
        set output to output & "BitRate: " & trackBitRate & "\n"
        set output to output & "BPM: " & trackBPM & "\n"
        set output to output & "===SOURCE===" & "\n"
        set output to output & "Kind: " & trackKind & "\n"
        set output to output & "CloudStatus: " & trackCloudStatus & "\n"
        set output to output & "Compilation: " & trackCompilation & "\n"
        set output to output & "LyricsLength: " & (length of trackLyrics) & "\n"
        set output to output & "===PLAYER===" & "\n"
        set output to output & "Position: " & playerPos & "\n"
        set output to output & "State: " & playerState & "\n"
        set output to output & "Volume: " & playerVolume & "\n"
        set output to output & "Shuffle: " & playerShuffle & "\n"
        set output to output & "Repeat: " & playerRepeat & "\n"
        set output to output & "===PLAYLIST===" & "\n"
        set output to output & "PlaylistName: " & playlistName & "\n"
        set output to output & "PlaylistDuration: " & playlistDuration & "\n"
        set output to output & "PlaylistCount: " & playlistCount & "\n"
        set output to output & "CurrentIndex: " & currentIndex

        return output

    on error errMsg
        return "ERROR: " & errMsg
    end try
end tell
"""

print("正在获取完整播放信息...\n")
let result = executeAppleScript(fullScript)

if result.hasPrefix("ERROR:") {
    print("❌ 获取失败: \(result)")
    exit(1)
}

// Parse and display results
let lines = result.components(separatedBy: "\n")
var currentSection = ""

for line in lines {
    if line.hasPrefix("===") && line.hasSuffix("===") {
        currentSection = line
        print("")
        print("╠════════════════════════════════════════════════════════════════╣")
        switch currentSection {
        case "===TRACK===":
            print("║  🎵 曲目信息")
        case "===IDENTIFIERS===":
            print("║  🏷️  标识符")
        case "===TIMING===":
            print("║  ⏱️  时间信息")
        case "===STATS===":
            print("║  📊 统计数据")
        case "===AUDIO===":
            print("║  🔊 音频参数")
        case "===SOURCE===":
            print("║  ☁️  来源信息")
        case "===PLAYER===":
            print("║  ▶️  播放状态")
        case "===PLAYLIST===":
            print("║  📋 播放列表")
        default:
            print("║  \(currentSection)")
        }
        print("╠════════════════════════════════════════════════════════════════╣")
    } else if line.contains(":") {
        let parts = line.components(separatedBy: ": ")
        if parts.count >= 2 {
            let key = parts[0]
            let value = parts[1]

            // Format specific fields
            var displayValue = value
            if key == "Duration" || key == "PlaylistDuration" {
                if let seconds = Double(value), seconds > 0 {
                    let m = Int(seconds) / 60
                    let s = Int(seconds) % 60
                    displayValue = "\(m):\(String(format: "%02d", s)) (\(Int(seconds))s)"
                }
            } else if key == "Position" {
                if let seconds = Double(value), seconds > 0 {
                    let m = Int(seconds) / 60
                    let s = Int(seconds) % 60
                    displayValue = "\(m):\(String(format: "%02d", s))"
                }
            } else if key == "Loved" {
                displayValue = value == "true" ? "❤️ Yes" : "No"
            } else if key == "Compilation" {
                displayValue = value == "true" ? "Yes" : "No"
            } else if key == "Shuffle" {
                displayValue = value == "true" ? "Enabled" : "Disabled"
            } else if key == "SampleRate" && value != "0" && value != "" {
                displayValue = "\(value) Hz"
            } else if key == "BitRate" && value != "0" && value != "" {
                displayValue = "\(value) kbps"
            } else if key == "Rating" && value != "0" {
                displayValue = "\(value)/100"
            }

            if key == "Name" || key == "Artist" || key == "Album" {
                print("  \(key): \(displayValue)")
            } else {
                print("  \(key): \(displayValue)")
            }
        }
    }
}

print("")
print("╚════════════════════════════════════════════════════════════════╝")
print("")
print("✅ 完整信息获取成功！")
