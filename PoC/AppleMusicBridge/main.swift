import Foundation

// MARK: - Apple Music Bridge
/// Minimal PoC for controlling Music.app via AppleScript

enum PlayerState: String {
    case playing = "playing"
    case paused = "paused"
    case stopped = "stopped"
    case unknown = "unknown"
}

struct NowPlayingInfo {
    let title: String?
    let artist: String?
    let position: Double
    let state: PlayerState
    let error: String?
}

class AppleMusicBridge {
    private let processInfo = ProcessInfo.processInfo
    private var startTime: Date?

    // MARK: - Check if Music.app is running
    func isMusicAppRunning() -> Bool {
        let script = """
        tell application "System Events"
            return (name of processes) contains "Music"
        end tell
        """
        let result = executeAppleScript(script)
        return result.lowercased() == "true"
    }

    // MARK: - Fetch Now Playing
    func fetchNowPlaying() -> NowPlayingInfo {
        // First check if Music.app is actually running
        guard isMusicAppRunning() else {
            return NowPlayingInfo(title: nil, artist: nil, position: 0, state: .stopped, error: "Music.app not running")
        }

        let script = """
        tell application "Music"
            try
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackPosition to player position
                set trackState to player state as string
                return "OK|" & trackName & "|" & trackArtist & "|" & trackPosition & "|" & trackState
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """

        let result = executeAppleScript(script)
        return parseNowPlayingResult(result)
    }

    // MARK: - Control Commands
    func playPause() -> (success: Bool, error: String?) {
        guard isMusicAppRunning() else {
            return (false, "Music.app not running")
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
        return (result == "OK", result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil)
    }

    func nextTrack() -> (success: Bool, error: String?) {
        guard isMusicAppRunning() else {
            return (false, "Music.app not running")
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
        return (result == "OK", result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil)
    }

    func previousTrack() -> (success: Bool, error: String?) {
        guard isMusicAppRunning() else {
            return (false, "Music.app not running")
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
        return (result == "OK", result.hasPrefix("ERROR:") ? String(result.dropFirst(6)) : nil)
    }

    // MARK: - Helpers
    private func executeAppleScript(_ source: String) -> String {
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
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.terminationStatus != 0 {
                return "ERROR:ExitCode_\(task.terminationStatus)"
            }
            return output
        } catch {
            return "ERROR:\(error.localizedDescription)"
        }
    }

    private func parseNowPlayingResult(_ result: String) -> NowPlayingInfo {
        if result.hasPrefix("ERROR:") {
            let errorMsg = String(result.dropFirst(6))
            return NowPlayingInfo(title: nil, artist: nil, position: 0, state: .unknown, error: errorMsg)
        }

        let parts = result.components(separatedBy: "|")
        guard parts.count >= 5, parts[0] == "OK" else {
            return NowPlayingInfo(title: nil, artist: nil, position: 0, state: .unknown, error: "Parse error: \(result)")
        }

        let title = parts[1].isEmpty ? nil : parts[1]
        let artist = parts[2].isEmpty ? nil : parts[2]
        let position = Double(parts[3]) ?? 0
        let state = PlayerState(rawValue: parts[4]) ?? .unknown

        return NowPlayingInfo(title: title, artist: artist, position: position, state: state, error: nil)
    }
}

// MARK: - Logger
class Logger {
    static func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] \(message)")
    }

    static func log(info: NowPlayingInfo) {
        if let error = info.error {
            log("ERROR: \(error)")
        } else {
            let title = info.title ?? "(no title)"
            let artist = info.artist ?? "(no artist)"
            let pos = String(format: "%.2f", info.position)
            log("🎵 \(title) - \(artist) [\(pos)s] (\(info.state.rawValue))")
        }
    }
}

// MARK: - Interactive Test Mode
func runInteractiveTest(bridge: AppleMusicBridge) {
    print("""
    ╔══════════════════════════════════════════════════════════════╗
    ║           AppleMusicBridge PoC - Interactive Mode            ║
    ╠══════════════════════════════════════════════════════════════╣
    ║ Commands:                                                     ║
    ║   r  - Read current playback info                            ║
    ║   p  - Play/Pause toggle                                     ║
    ║   n  - Next track                                            ║
    ║   b  - Previous track                                        ║
    ║   l  - Start 30s polling test                                ║
    ║   q  - Quit                                                  ║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    while true {
        print("\n> ", terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            continue
        }

        switch input {
        case "r":
            Logger.log("--- Reading current playback ---")
            let info = bridge.fetchNowPlaying()
            Logger.log(info: info)

        case "p":
            Logger.log("--- Sending Play/Pause ---")
            let result = bridge.playPause()
            Logger.log(result.success ? "✅ Play/Pause success" : "❌ Play/Pause failed: \(result.error ?? "unknown")")
            // Read back state
            Thread.sleep(forTimeInterval: 0.2)
            let info = bridge.fetchNowPlaying()
            Logger.log(info: info)

        case "n":
            Logger.log("--- Sending Next Track ---")
            let result = bridge.nextTrack()
            Logger.log(result.success ? "✅ Next track success" : "❌ Next track failed: \(result.error ?? "unknown")")
            Thread.sleep(forTimeInterval: 0.5)
            let info = bridge.fetchNowPlaying()
            Logger.log(info: info)

        case "b":
            Logger.log("--- Sending Previous Track ---")
            let result = bridge.previousTrack()
            Logger.log(result.success ? "✅ Previous track success" : "❌ Previous track failed: \(result.error ?? "unknown")")
            Thread.sleep(forTimeInterval: 0.5)
            let info = bridge.fetchNowPlaying()
            Logger.log(info: info)

        case "l":
            runPollingTest(bridge: bridge)

        case "q", "quit", "exit":
            Logger.log("Goodbye!")
            return

        default:
            print("Unknown command: '\(input)'. Use r, p, n, b, l, or q")
        }
    }
}

// MARK: - Polling Test
func runPollingTest(bridge: AppleMusicBridge) {
    print("\n" + String(repeating: "=", count: 60))
    Logger.log("Starting 30-second polling test...")
    Logger.log("Polling every 0.5 seconds")
    print(String(repeating: "=", count: 60) + "\n")

    let startTime = Date()
    let duration: TimeInterval = 30
    var pollCount = 0
    var errorCount = 0
    var lastPosition: Double = 0
    var stuckCount = 0

    while Date().timeIntervalSince(startTime) < duration {
        let info = bridge.fetchNowPlaying()
        pollCount += 1

        if info.error != nil {
            errorCount += 1
        } else {
            // Check if position is stuck
            if info.state == .playing && abs(info.position - lastPosition) < 0.1 && pollCount > 1 {
                stuckCount += 1
            }
            lastPosition = info.position

            // Log every 2 seconds (every 4th poll)
            if pollCount % 4 == 0 {
                Logger.log(info: info)
            }
        }

        Thread.sleep(forTimeInterval: 0.5)
    }

    print("\n" + String(repeating: "=", count: 60))
    Logger.log("Polling Test Complete")
    print("  Total polls: \(pollCount)")
    print("  Errors: \(errorCount)")
    print("  Stuck detections: \(stuckCount)")
    print("  Success rate: \(String(format: "%.1f", 100.0 * Double(pollCount - errorCount) / Double(pollCount)))%")
    print(String(repeating: "=", count: 60) + "\n")
}

// MARK: - Main
print("""
╔════════════════════════════════════════════════════════════════╗
║     AppleMusicBridge PoC - Music.app Control Verification      ║
╠════════════════════════════════════════════════════════════════╣
║  Purpose: Verify Music.app control via AppleScript             ║
║  Method: NSAppleScript via osascript wrapper                   ║
╚════════════════════════════════════════════════════════════════╝
""")

let bridge = AppleMusicBridge()

// Initial read
Logger.log("Initial state check:")
let initialInfo = bridge.fetchNowPlaying()
Logger.log(info: initialInfo)

// Start interactive mode
runInteractiveTest(bridge: bridge)
