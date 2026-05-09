//
//  AppleMusicBridge.swift
//  myPlayer2
//
//  AppleScript bridge for Music.app playback state and controls.
//

import AppKit
import Foundation

final class AppleMusicBridge: @unchecked Sendable {
    enum FetchIssue: Sendable {
        case appNotRunning
        case emptyResponse
        case invalidResponse(itemCount: Int)
        case noNowPlayingData(snapshot: NowPlayingInfo)
        case busy(message: String)
        case timeout(message: String)
        case scriptError(message: String)
    }

    enum FetchResult: Sendable {
        case success(NowPlayingInfo)
        case failure(FetchIssue)
    }

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

    struct ArtworkSnapshot: Sendable {
        var data: Data
        var info: NowPlayingInfo
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
        switch fetchFullInfoResult() {
        case .success(let info):
            return info
        case .failure(let issue):
            switch issue {
            case .appNotRunning:
                return NowPlayingInfo(state: .stopped)
            case .noNowPlayingData(let snapshot):
                return snapshot
            case .emptyResponse, .invalidResponse, .busy, .timeout, .scriptError:
                return NowPlayingInfo(state: .unknown)
            }
        }
    }

    nonisolated func fetchFullInfoResult() -> FetchResult {
        guard isMusicAppRunning() else {
            return .failure(.appNotRunning)
        }

        let execution = executeDetailed(fetchFullScript)
        if let errorNumber = execution.errorNumber,
           let issue = classifyExecutionError(number: errorNumber, message: execution.errorMessage) {
            return .failure(issue)
        }
        if let errorMessage = execution.errorMessage, !errorMessage.isEmpty {
            return .failure(.scriptError(message: errorMessage))
        }
        guard let descriptor = execution.descriptor else {
            return .failure(.emptyResponse)
        }
        guard descriptor.numberOfItems > 0 else {
            return .failure(.emptyResponse)
        }

        let status = descriptor.atIndex(1)?.stringValue ?? ""
        switch status {
        case "ok":
            guard descriptor.numberOfItems >= 14 else {
                return .failure(.invalidResponse(itemCount: descriptor.numberOfItems))
            }
            return .success(parseFullInfo(from: descriptor, startIndex: 2))
        case "trackError":
            guard descriptor.numberOfItems >= 8 else {
                return .failure(.invalidResponse(itemCount: descriptor.numberOfItems))
            }
            let errorNumber = Int(descriptor.atIndex(2)?.stringValue ?? "")
            let message = descriptor.atIndex(3)?.stringValue ?? "unknown track error"
            let snapshot = NowPlayingInfo(
                title: nil,
                artist: nil,
                album: nil,
                albumArtist: nil,
                duration: 0,
                position: descriptor.atIndex(8)?.doubleValue ?? 0,
                state: PlayerState(rawValue: descriptor.atIndex(4)?.stringValue ?? "") ?? .unknown,
                volume: Int(descriptor.atIndex(5)?.int32Value ?? 100),
                persistentID: nil,
                trackNumber: 0,
                year: 0,
                shuffleEnabled: descriptor.atIndex(6)?.booleanValue ?? false,
                songRepeat: RepeatMode(rawValue: descriptor.atIndex(7)?.stringValue ?? "") ?? .unknown
            )
            if let issue = classifyTrackReadError(number: errorNumber, message: message, snapshot: snapshot) {
                return .failure(issue)
            }
            return .failure(.scriptError(message: formattedError(number: errorNumber, message: message)))
        case "error":
            let errorNumber = Int(descriptor.atIndex(2)?.stringValue ?? "")
            let message = descriptor.atIndex(3)?.stringValue ?? "unknown error"
            if let issue = classifyExecutionError(number: errorNumber, message: message) {
                return .failure(issue)
            }
            return .failure(.scriptError(message: formattedError(number: errorNumber, message: message)))
        default:
            return .failure(.scriptError(message: "unexpected fetch status: \(status)"))
        }
    }

    private nonisolated func parseFullInfo(
        from descriptor: NSAppleEventDescriptor,
        startIndex: Int
    ) -> NowPlayingInfo {
        let stateRaw = descriptor.atIndex(startIndex + 6)?.stringValue ?? ""
        let repeatRaw = descriptor.atIndex(startIndex + 12)?.stringValue ?? ""
        return NowPlayingInfo(
            title: nonEmptyString(descriptor.atIndex(startIndex)?.stringValue),
            artist: nonEmptyString(descriptor.atIndex(startIndex + 1)?.stringValue),
            album: nonEmptyString(descriptor.atIndex(startIndex + 2)?.stringValue),
            albumArtist: nonEmptyString(descriptor.atIndex(startIndex + 3)?.stringValue),
            duration: descriptor.atIndex(startIndex + 4)?.doubleValue ?? 0,
            position: descriptor.atIndex(startIndex + 5)?.doubleValue ?? 0,
            state: PlayerState(rawValue: stateRaw) ?? .unknown,
            volume: Int(descriptor.atIndex(startIndex + 7)?.int32Value ?? 100),
            persistentID: nonEmptyString(descriptor.atIndex(startIndex + 8)?.stringValue),
            trackNumber: Int(descriptor.atIndex(startIndex + 9)?.int32Value ?? 0),
            year: Int(descriptor.atIndex(startIndex + 10)?.int32Value ?? 0),
            shuffleEnabled: descriptor.atIndex(startIndex + 11)?.booleanValue ?? false,
            songRepeat: RepeatMode(rawValue: repeatRaw) ?? .unknown
        )
    }

    nonisolated func fetchCurrentArtworkData() -> Data? {
        fetchCurrentArtworkSnapshot()?.data
    }

    nonisolated func fetchCurrentArtworkSnapshot() -> ArtworkSnapshot? {
        guard isMusicAppRunning() else { return nil }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("myPlayer2-am-artwork-\(UUID().uuidString)")
            .appendingPathExtension("art")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let path = appleScriptStringLiteral(tempURL.path)
        let source = """
        with timeout of 8 seconds
            tell application "Music"
                try
                    set currentPlayerState to player state as string
                    try
                        set currentPosition to player position
                    on error
                        set currentPosition to 0
                    end try
                    try
                        set currentSoundVolume to sound volume
                    on error
                        set currentSoundVolume to 100
                    end try
                    try
                        set currentShuffle to shuffle enabled
                    on error
                        set currentShuffle to false
                    end try
                    try
                        set currentRepeat to song repeat as string
                    on error
                        set currentRepeat to "unknown"
                    end try
                    set trk to current track
                    if (count of artworks of trk) is 0 then return {"noArtwork"}
                    set artworkData to data of artwork 1 of trk
                    set targetFile to POSIX file "\(path)"
                    set fileRef to open for access targetFile with write permission
                    set eof of fileRef to 0
                    write artworkData to fileRef
                    close access fileRef
                    return {"ok", name of trk, artist of trk, album of trk, album artist of trk, duration of trk, currentPosition, currentPlayerState, currentSoundVolume, persistent ID of trk, track number of trk, year of trk, currentShuffle, currentRepeat}
                on error
                    try
                        close access POSIX file "\(path)"
                    end try
                    return {"error"}
                end try
            end tell
        end timeout
        """

        guard let descriptor = runSource(source),
              descriptor.numberOfItems >= 14,
              descriptor.atIndex(1)?.stringValue == "ok",
              let data = try? Data(contentsOf: tempURL),
              !data.isEmpty,
              NSImage(data: data) != nil else {
            return nil
        }
        return ArtworkSnapshot(data: data, info: parseFullInfo(from: descriptor, startIndex: 2))
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
                    set currentPlayerState to player state as string
                    try
                        set currentPosition to player position
                    on error
                        set currentPosition to 0
                    end try
                    try
                        set currentSoundVolume to sound volume
                    on error
                        set currentSoundVolume to 100
                    end try
                    try
                        set currentShuffle to shuffle enabled
                    on error
                        set currentShuffle to false
                    end try
                    try
                        set currentRepeat to song repeat as string
                    on error
                        set currentRepeat to "unknown"
                    end try
                    try
                        set trk to current track
                        return {"ok", name of trk, artist of trk, album of trk, album artist of trk, duration of trk, currentPosition, currentPlayerState, currentSoundVolume, persistent ID of trk, track number of trk, year of trk, currentShuffle, currentRepeat}
                    on error errMsg number errNum
                        return {"trackError", errNum as string, errMsg, currentPlayerState, currentSoundVolume, currentShuffle, currentRepeat, currentPosition}
                    end try
                on error errMsg number errNum
                    return {"error", errNum as string, errMsg}
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

    private nonisolated func executeDetailed(
        _ script: NSAppleScript?
    ) -> (descriptor: NSAppleEventDescriptor?, errorNumber: Int?, errorMessage: String?) {
        guard let script else {
            return (
                descriptor: nil,
                errorNumber: nil,
                errorMessage: "missing compiled AppleScript"
            )
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        return (
            descriptor: descriptor,
            errorNumber: error?[NSAppleScript.errorNumber] as? Int,
            errorMessage: error?[NSAppleScript.errorMessage] as? String
        )
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

    private nonisolated func classifyExecutionError(number: Int?, message: String?) -> FetchIssue? {
        if isTimeoutError(number: number, message: message) {
            return .timeout(message: formattedError(number: number, message: message))
        }
        if isBusyError(number: number, message: message) {
            return .busy(message: formattedError(number: number, message: message))
        }
        guard number != nil || message != nil else { return nil }
        return .scriptError(message: formattedError(number: number, message: message))
    }

    private nonisolated func classifyTrackReadError(
        number: Int?,
        message: String?,
        snapshot: NowPlayingInfo
    ) -> FetchIssue? {
        if isTimeoutError(number: number, message: message) {
            return .timeout(message: formattedError(number: number, message: message))
        }
        if isBusyError(number: number, message: message) {
            return .busy(message: formattedError(number: number, message: message))
        }
        if isNoCurrentTrackError(number: number, message: message) {
            return .noNowPlayingData(snapshot: snapshot)
        }
        return nil
    }

    private nonisolated func isTimeoutError(number: Int?, message: String?) -> Bool {
        let lowercased = message?.lowercased() ?? ""
        return number == -1712 || lowercased.contains("timeout") || message?.contains("超时") == true
    }

    private nonisolated func isBusyError(number: Int?, message: String?) -> Bool {
        let lowercased = message?.lowercased() ?? ""
        return number == -1708
            || lowercased.contains("busy")
            || lowercased.contains("resource busy")
            || message?.contains("忙") == true
    }

    private nonisolated func isNoCurrentTrackError(number: Int?, message: String?) -> Bool {
        let lowercased = message?.lowercased() ?? ""
        return number == -1728
            || lowercased.contains("current track")
            || lowercased.contains("can't get current track")
            || message?.contains("当前音轨") == true
            || message?.contains("无法取得 current track") == true
    }

    private nonisolated func formattedError(number: Int?, message: String?) -> String {
        let messageText = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (number, messageText?.isEmpty == false ? messageText : nil) {
        case let (.some(number), .some(message)):
            return "code=\(number) message=\(message)"
        case let (.some(number), nil):
            return "code=\(number)"
        case let (nil, .some(message)):
            return message
        case (nil, nil):
            return "unknown AppleScript error"
        }
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
