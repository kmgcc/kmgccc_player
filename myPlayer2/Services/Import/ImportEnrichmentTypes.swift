//
//  ImportEnrichmentTypes.swift
//  myPlayer2
//

import Foundation

nonisolated enum ImportEnrichmentPart: String, Sendable, Hashable {
    case lyrics
    case cover

    var label: String {
        switch self {
        case .lyrics: return "歌词"
        case .cover: return "封面"
        }
    }
}

nonisolated enum ImportEnrichmentPartState: String, Sendable {
    case pending
    case running
    case flushPending
    case completed
    case failed
    case noResults
    case skipped

    var isOutstanding: Bool {
        self == .pending || self == .running || self == .flushPending
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .noResults, .skipped:
            return true
        case .pending, .running, .flushPending:
            return false
        }
    }

    var countsAsFailure: Bool {
        self == .failed || self == .noResults
    }
}

nonisolated struct ImportEnrichmentPartRequest: Sendable, Hashable {
    let trackID: UUID
    let part: ImportEnrichmentPart
}

nonisolated struct ImportEnrichmentItemState: Sendable {
    let trackID: UUID
    var title: String
    var artist: String
    var album: String
    var lyricsState: ImportEnrichmentPartState
    var coverState: ImportEnrichmentPartState
    var lyricAttempts: Int
    var coverAttempts: Int

    func state(for part: ImportEnrichmentPart) -> ImportEnrichmentPartState {
        switch part {
        case .lyrics: return lyricsState
        case .cover: return coverState
        }
    }

    mutating func setState(_ state: ImportEnrichmentPartState, for part: ImportEnrichmentPart) {
        switch part {
        case .lyrics:
            lyricsState = state
        case .cover:
            coverState = state
        }
    }

    func attempts(for part: ImportEnrichmentPart) -> Int {
        switch part {
        case .lyrics: return lyricAttempts
        case .cover: return coverAttempts
        }
    }

    mutating func incrementAttempts(for part: ImportEnrichmentPart) {
        switch part {
        case .lyrics:
            lyricAttempts += 1
        case .cover:
            coverAttempts += 1
        }
    }

    var hasOutstandingWork: Bool {
        lyricsState.isOutstanding || coverState.isOutstanding
    }

    var isTerminal: Bool {
        lyricsState.isTerminal && coverState.isTerminal
    }

    var hasTerminalFailure: Bool {
        lyricsState.countsAsFailure || coverState.countsAsFailure
    }

    var flushPendingPartCount: Int {
        [lyricsState, coverState].filter { $0 == .flushPending }.count
    }
}

nonisolated struct ImportEnrichmentProgressSnapshot: Sendable, Equatable {
    let totalEnqueued: Int
    let completedCount: Int
    let failedCount: Int
    let pendingLyricsCount: Int
    let pendingCoverCount: Int
    let runningCount: Int
    let flushPendingCount: Int

    var hasOutstandingWork: Bool {
        pendingLyricsCount > 0 || pendingCoverCount > 0 || runningCount > 0 || flushPendingCount > 0
    }

    var sidebarText: String {
        var parts: [String] = [
            "补全中 \(completedCount)/\(totalEnqueued)"
        ]
        if runningCount > 0 {
            parts.append("进行中 \(runningCount)")
        }
        if flushPendingCount > 0 {
            parts.append("待提交 \(flushPendingCount)")
        }
        if pendingLyricsCount > 0 || pendingCoverCount > 0 {
            parts.append("词\(pendingLyricsCount) 封\(pendingCoverCount)")
        }
        if failedCount > 0 {
            parts.append("失败 \(failedCount)")
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated struct PendingTrackEnrichmentPatch: Sendable {
    let trackID: UUID
    var ttmlLyricText: String?
    var artworkData: Data?
    var lyricShouldFlush: Bool
    var coverShouldFlush: Bool

    init(trackID: UUID) {
        self.trackID = trackID
        self.ttmlLyricText = nil
        self.artworkData = nil
        self.lyricShouldFlush = false
        self.coverShouldFlush = false
    }
}
