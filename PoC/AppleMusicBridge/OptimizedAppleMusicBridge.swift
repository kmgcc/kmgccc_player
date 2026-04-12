import Foundation
import Cocoa

public final class OptimizedAppleMusicBridge {
    public static let shared = OptimizedAppleMusicBridge()
    
    private var checkRunningScript: NSAppleScript?
    private var fetchPositionScript: NSAppleScript?
    private var fetchFullScript: NSAppleScript?
    
    public enum PlayerState: String, Sendable {
        case playing = "playing"
        case paused = "paused"
        case stopped = "stopped"
        case unknown = "unknown"
    }
    
    public enum RepeatMode: String, Sendable {
        case off = "off"
        case one = "one"
        case all = "all"
        case unknown = "unknown"
    }
    
    public struct NowPlayingInfo: Sendable {
        public let title: String?
        public let artist: String?
        public let album: String?
        public let albumArtist: String?
        public let duration: Double
        public let position: Double
        public let state: PlayerState
        public let volume: Int
        public let persistentID: String?
        public let trackNumber: Int
        public let year: Int
        public let shuffleEnabled: Bool
        public let songRepeat: RepeatMode
    }
    
    private init() {
        compileScripts()
    }
    
    private func compileScripts() {
        // Check if Music is running
        checkRunningScript = NSAppleScript(source: 
            "tell application \"System Events\" to return (name of processes) contains \"Music\"")
        
        // Light query: position and state only
        fetchPositionScript = NSAppleScript(source:
            "tell application \"Music\" to try\n" +
            "return (player position as string) & \"|\" & (player state as string)\n" +
            "on error\n" +
            "return \"0|stopped\"\n" +
            "end try")

        // Full query using AppleScript list (avoids JSON escaping issues)
        // Returns: title|artist|album|albumArtist|duration|position|state|volume|persistentID|trackNumber|year|shuffle|repeat
        fetchFullScript = NSAppleScript(source:
            "tell application \"Music\"\n" +
            "try\n" +
            "set trk to current track\n" +
            "set nm to name of trk\n" +
            "set ar to artist of trk\n" +
            "set al to album of trk\n" +
            "set aa to album artist of trk\n" +
            "set dur to duration of trk\n" +
            "set pos to player position\n" +
            "set sta to player state as string\n" +
            "set vol to sound volume\n" +
            "set pid to persistent ID of trk\n" +
            "set tn to track number of trk\n" +
            "set yr to year of trk\n" +
            "set shf to shuffle enabled\n" +
            "set rpt to song repeat as string\n" +
            "return nm & \"|\" & ar & \"|\" & al & \"|\" & aa & \"|\" & dur & \"|\" & pos & \"|\" & sta & \"|\" & vol & \"|\" & pid & \"|\" & tn & \"|\" & yr & \"|\" & shf & \"|\" & rpt\n" +
            "on error e\n" +
            "return \"ERROR|\" & e\n" +
            "end try\n" +
            "end tell")
    }
    
    public func isMusicAppRunning() -> Bool {
        guard let script = checkRunningScript else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return result.stringValue?.lowercased() == "true"
    }
    
    public func fetchPositionInfo() -> NowPlayingInfo {
        guard isMusicAppRunning() else {
            return NowPlayingInfo(state: .stopped)
        }
        guard let script = fetchPositionScript else {
            return NowPlayingInfo(state: .unknown)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let str = result.stringValue ?? "0|unknown"
        
        let parts = str.components(separatedBy: "|")
        let position = Double(parts[0]) ?? 0
        let state = PlayerState(rawValue: parts[1]) ?? .unknown
        
        return NowPlayingInfo(position: position, state: state)
    }
    
    public func fetchFullInfo() -> NowPlayingInfo {
        guard isMusicAppRunning() else {
            return NowPlayingInfo(state: .stopped)
        }
        guard let script = fetchFullScript else {
            return NowPlayingInfo(state: .unknown)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let str = result.stringValue ?? "ERROR|unknown"
        
        if str.hasPrefix("ERROR|") {
            return NowPlayingInfo(state: .unknown)
        }
        
        let parts = str.components(separatedBy: "|")
        guard parts.count >= 13 else {
            return NowPlayingInfo(state: .unknown)
        }
        
        // Parse values with fallbacks for empty strings
        let title = parts[0].isEmpty ? nil : parts[0]
        let artist = parts[1].isEmpty ? nil : parts[1]
        let album = parts[2].isEmpty ? nil : parts[2]
        let albumArtist = parts[3].isEmpty ? nil : parts[3]
        let duration = Double(parts[4]) ?? 0
        let position = Double(parts[5]) ?? 0
        let state = PlayerState(rawValue: parts[6]) ?? .unknown
        let volume = Int(parts[7]) ?? 100
        let persistentID = parts[8].isEmpty ? nil : parts[8]
        let trackNumber = Int(parts[9]) ?? 0
        let year = Int(parts[10]) ?? 0
        let shuffleEnabled = parts[11].lowercased() == "true"
        let songRepeat = RepeatMode(rawValue: parts[12]) ?? .unknown
        
        return NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            duration: duration,
            position: position,
            state: state,
            volume: volume,
            persistentID: persistentID,
            trackNumber: trackNumber,
            year: year,
            shuffleEnabled: shuffleEnabled,
            songRepeat: songRepeat
        )
    }
}

// Convenience init
extension OptimizedAppleMusicBridge.NowPlayingInfo {
    init(position: Double = 0, state: OptimizedAppleMusicBridge.PlayerState) {
        self.title = nil
        self.artist = nil
        self.album = nil
        self.albumArtist = nil
        self.duration = 0
        self.position = position
        self.state = state
        self.volume = 100
        self.persistentID = nil
        self.trackNumber = 0
        self.year = 0
        self.shuffleEnabled = false
        self.songRepeat = .unknown
    }
}

// Debug
extension OptimizedAppleMusicBridge.NowPlayingInfo {
    public var debugDescription: String {
        var lines: [String] = []
        lines.append("Title: \(title ?? "nil")")
        lines.append("Artist: \(artist ?? "nil")")
        lines.append("Album: \(album ?? "nil")")
        lines.append("Album Artist: \(albumArtist ?? "nil")")
        lines.append("Persistent ID: \(persistentID ?? "nil")")
        lines.append("Duration: \(duration)")
        lines.append("Position: \(position)")
        lines.append("State: \(state)")
        lines.append("Volume: \(volume)")
        lines.append("Track Number: \(trackNumber)")
        lines.append("Year: \(year)")
        lines.append("Shuffle: \(shuffleEnabled)")
        lines.append("Repeat: \(songRepeat)")
        return lines.joined(separator: "\n")
    }
}
