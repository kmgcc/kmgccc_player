//
//  AppleMusicBridge.swift
//  myPlayer2
//
//  AppleScript bridge for Music.app playback state and controls.
//

import AppKit
import Foundation

final class AppleMusicBridge: @unchecked Sendable {
    enum PlayerState: String, Sendable {
        case playing
        case paused
        case stopped
        case unknown
    }

    enum RepeatMode: String, Sendable {
        case off
        case one
        case all
        case unknown
    }

    struct NowPlayingInfo: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var duration: Double
        var position: Double
        var state: PlayerState
        var volume: Int
        var persistentID: String?
        var trackNumber: Int
        var year: Int
        var shuffleEnabled: Bool
        var songRepeat: RepeatMode
    }

    nonisolated(unsafe) private var fetchPositionScript: NSAppleScript?
    nonisolated(unsafe) private var fetchFullScript: NSAppleScript?
    nonisolated(unsafe) private var controlScripts: [ControlScript: NSAppleScript] = [:]

    init() {
        compileScripts()
    }

    nonisolated func isMusicAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    @MainActor
    func launchMusicApp() -> Bool {
        let candidates = [
            "/System/Applications/Music.app",
            "/Applications/Music.app"
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }
        return NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    nonisolated func fetchPositionInfo() -> NowPlayingInfo {
        guard isMusicAppRunning() else {
            return NowPlayingInfo(state: .stopped)
        }
        guard let descriptor = execute(fetchPositionScript), descriptor.numberOfItems >= 2 else {
            return NowPlayingInfo(state: .unknown)
        }

        let position = descriptor.atIndex(1)?.doubleValue ?? 0
        let stateRaw = descriptor.atIndex(2)?.stringValue ?? ""
        return NowPlayingInfo(position: position, state: PlayerState(rawValue: stateRaw) ?? .unknown)
    }

    nonisolated func fetchFullInfo() -> NowPlayingInfo {
        guard isMusicAppRunning() else {
            return NowPlayingInfo(state: .stopped)
        }
        guard let descriptor = execute(fetchFullScript), descriptor.numberOfItems >= 13 else {
            return NowPlayingInfo(state: .unknown)
        }

        let stateRaw = descriptor.atIndex(7)?.stringValue ?? ""
        let repeatRaw = descriptor.atIndex(13)?.stringValue ?? ""

        return NowPlayingInfo(
            title: nonEmptyString(descriptor.atIndex(1)?.stringValue),
            artist: nonEmptyString(descriptor.atIndex(2)?.stringValue),
            album: nonEmptyString(descriptor.atIndex(3)?.stringValue),
            albumArtist: nonEmptyString(descriptor.atIndex(4)?.stringValue),
            duration: descriptor.atIndex(5)?.doubleValue ?? 0,
            position: descriptor.atIndex(6)?.doubleValue ?? 0,
            state: PlayerState(rawValue: stateRaw) ?? .unknown,
            volume: Int(descriptor.atIndex(8)?.int32Value ?? 100),
            persistentID: nonEmptyString(descriptor.atIndex(9)?.stringValue),
            trackNumber: Int(descriptor.atIndex(10)?.int32Value ?? 0),
            year: Int(descriptor.atIndex(11)?.int32Value ?? 0),
            shuffleEnabled: descriptor.atIndex(12)?.booleanValue ?? false,
            songRepeat: RepeatMode(rawValue: repeatRaw) ?? .unknown
        )
    }

    nonisolated func fetchCurrentArtworkData() -> Data? {
        guard isMusicAppRunning() else { return nil }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("myPlayer2-am-artwork-\(UUID().uuidString)")
            .appendingPathExtension("art")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let path = appleScriptStringLiteral(tempURL.path)
        let source = """
        tell application "Music"
            try
                set trk to current track
                if (count of artworks of trk) is 0 then return false
                set artworkData to data of artwork 1 of trk
                set targetFile to POSIX file "\(path)"
                set fileRef to open for access targetFile with write permission
                set eof of fileRef to 0
                write artworkData to fileRef
                close access fileRef
                return true
            on error
                try
                    close access POSIX file "\(path)"
                end try
                return false
            end try
        end tell
        """

        guard runSource(source)?.booleanValue == true,
              let data = try? Data(contentsOf: tempURL),
              !data.isEmpty,
              NSImage(data: data) != nil else {
            return nil
        }
        return data
    }

    @discardableResult
    nonisolated func playPause() -> Bool {
        execute(controlScripts[.playPause]) != nil
    }

    @discardableResult
    nonisolated func play() -> Bool {
        execute(controlScripts[.play]) != nil
    }

    @discardableResult
    nonisolated func pause() -> Bool {
        execute(controlScripts[.pause]) != nil
    }

    @discardableResult
    nonisolated func nextTrack() -> Bool {
        execute(controlScripts[.nextTrack]) != nil
    }

    @discardableResult
    nonisolated func previousTrack() -> Bool {
        execute(controlScripts[.previousTrack]) != nil
    }

    @discardableResult
    nonisolated func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite else { return false }
        let clamped = max(0, seconds)
        let value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
        return runSource("tell application \"Music\" to set player position to \(value)") != nil
    }

    @discardableResult
    nonisolated func setVolume(_ volume: Double) -> Bool {
        let clamped = Int(max(0, min(1, volume)) * 100)
        return runSource("tell application \"Music\" to set sound volume to \(clamped)") != nil
    }

    @discardableResult
    nonisolated func setShuffleEnabled(_ enabled: Bool) -> Bool {
        runSource("tell application \"Music\" to set shuffle enabled to \(enabled ? "true" : "false")") != nil
    }

    @discardableResult
    nonisolated func setRepeatMode(_ mode: RepeatMode) -> Bool {
        switch mode {
        case .off:
            return runSource("tell application \"Music\" to set song repeat to off") != nil
        case .one:
            return runSource("tell application \"Music\" to set song repeat to one") != nil
        case .all:
            return runSource("tell application \"Music\" to set song repeat to all") != nil
        case .unknown:
            return false
        }
    }

    private nonisolated func compileScripts() {
        fetchPositionScript = compile(
            """
            tell application "Music"
                try
                    return {player position, player state as string}
                on error
                    return {0, "stopped"}
                end try
            end tell
            """
        )

        fetchFullScript = compile(
            """
            tell application "Music"
                try
                    set trk to current track
                    return {name of trk, artist of trk, album of trk, album artist of trk, duration of trk, player position, player state as string, sound volume, persistent ID of trk, track number of trk, year of trk, shuffle enabled, song repeat as string}
                on error
                    return {}
                end try
            end tell
            """
        )

        controlScripts[.playPause] = compile("tell application \"Music\" to playpause")
        controlScripts[.play] = compile("tell application \"Music\" to play")
        controlScripts[.pause] = compile("tell application \"Music\" to pause")
        controlScripts[.nextTrack] = compile("tell application \"Music\" to next track")
        controlScripts[.previousTrack] = compile("tell application \"Music\" to previous track")
    }

    private nonisolated func compile(_ source: String) -> NSAppleScript? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        return error == nil ? script : nil
    }

    @discardableResult
    private nonisolated func execute(_ script: NSAppleScript?) -> NSAppleEventDescriptor? {
        guard let script else { return nil }
        var error: NSDictionary?
        return script.executeAndReturnError(&error)
    }

    @discardableResult
    private nonisolated func runSource(_ source: String) -> NSAppleEventDescriptor? {
        execute(compile(source))
    }

    private nonisolated func nonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private nonisolated func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private enum ControlScript: Hashable, Sendable {
        case playPause
        case play
        case pause
        case nextTrack
        case previousTrack
    }
}

extension AppleMusicBridge.NowPlayingInfo {
    nonisolated init(position: Double = 0, state: AppleMusicBridge.PlayerState) {
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
